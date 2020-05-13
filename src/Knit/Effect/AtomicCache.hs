{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-|
Module      : Knit.Effect.AtomicCache
Description : Effect for managing a persistent cache of serializable things to avoid redoing computations
Copyright   : (c) Adam Conner-Sax 2019
License     : BSD-3-Clause
Maintainer  : adam_conner_sax@yahoo.com
Stability   : experimental

This module implementes the `DataCache` polysemy effect for managing a keyed cache of serialized
things.  It allows simple maintaining of disk-backed storage of computational results as long as
they are serializable.

<https://github.com/adamConnerSax/knit-haskell/tree/master/examples Examples> are available, and might be useful for seeing how all this works.
-}
module Knit.Effect.AtomicCache
  (
    -- * Effect
    AtomicCache
  , SimpleCache
    -- * Actions
--  , cacheLookup
--  , cacheUpdate  
  , encodeAndStore
  , retrieveAndDecode
  , lookupAndDecode
  , retrieveOrMake
  , clear
    -- * Serialization
  , Serialize(..)
    -- * Persistance
  , persistAsByteString
  , persistAsStrictByteString
  , persistAsByteStreamly
  , persistAsByteArray
    -- * Interpretations
  , runAtomicInMemoryCache
  , runBackedAtomicInMemoryCache
  , runPersistenceBackedAtomicInMemoryCache
  , runPersistenceBackedAtomicInMemoryCache'
    -- * Exceptions
  , CacheError(..)
  )
where

import qualified Polysemy                      as P
import qualified Polysemy.Error                as P
import qualified Knit.Effect.Logger            as K

import qualified Data.ByteString               as BS
import qualified Data.ByteString.Lazy          as BL
import           Data.Functor.Identity          (Identity(..))
import           Data.Int (Int64)
import qualified Data.Map                      as M
import qualified Data.Text                     as T
import qualified Data.Word                     as Word

import qualified Control.Concurrent.STM        as C
import qualified Control.Exception             as Exception
--import qualified Control.Monad.Exception       as MTL.Exception
import           Control.Monad                  ( join )
--import           Control.Monad.IO.Class         ( MonadIO(liftIO) )

import qualified Streamly                      as Streamly
import qualified Streamly.Prelude              as Streamly
import qualified Streamly.Internal.Memory.Array         as Streamly.Array
import qualified Streamly.FileSystem.Handle    as Streamly.Handle
import qualified Streamly.Internal.FileSystem.File as Streamly.File

import qualified System.IO                     as System
import qualified System.Directory              as System
import qualified System.IO.Error               as IO.Error


{- TODO:
1. Can this deisgn be simplified, part 1. The Maybe in the TMVar seems like it should be uneccessary.
2. Can this design be simplified, part 2. Returning the emptyTMVar from the lookup seems...leaky.
Can this be done in a way so that it must be filled?
3. We should be able to factor out some things around handling the returned TMVar
-}

data CacheError =
  ItemNotFoundError T.Text
  | DeSerializationError T.Text
  | PersistError T.Text
  | OtherCacheError T.Text deriving (Show, Eq)

-- encode has a weird return type because sometimes a is monadic and we need to run something to get the result.
-- The a we return should be just be a stored version.  It will often be the a we input.

data Serialize r a ct where
  Serialize :: (P.MemberWithError (P.Error CacheError) r)
            => (a -> P.Sem r (ct, a)) -- encode
            -> (ct -> P.Sem r a) -- decode
            -> (ct -> Int64) -- size (in Bytes)
            -> Serialize r a ct

-- | This is a Key/Value store
-- | Tagged by @t@ so we can have more than one for the same k and v
-- | h is a type we use for holding a resource
data Cache k v h m a where
  CacheLookup :: k -> Cache k v h m (Either h v)
  CacheUpdate :: k -> Maybe v -> Cache k v h m ()
  
P.makeSem ''Cache

-- | Combinator to combine the action of serializing and caching
encodeAndStore
  :: forall h ct k a r.
     ( Show k
     , P.Member (Cache k ct h) r
     , K.LogWithPrefixesLE r
     )
  => Serialize r a ct
  -> k
  -> a
  -> P.Sem r ()
encodeAndStore (Serialize encode _ encBytes) k x =
  K.wrapPrefix ("AtomicCache.encodeAndStore (key=" <> (T.pack $ show k) <> ")") $ do
    K.logLE K.Diagnostic $ "encoding (serializing) data for key=" <> (T.pack $ show k) 
    encoded <- fst <$> encode x
    let nBytes = encBytes encoded
    K.logLE K.Diagnostic $ "Storing " <> (T.pack $ show nBytes) <> " bytes of encoded data in cache for key=" <> (T.pack $ show k) 
    cacheUpdate k (Just encoded)
{-# INLINEABLE encodeAndStore #-}

-- We need some exception handling here to make sure the TMVar gets filled somehow
handleAtomicLookup
  :: ( P.Members [AtomicCache k ct, P.Embed IO] r
     ,  K.LogWithPrefixesLE r
     , Show k
     )
  => Serialize r a ct -> P.Sem r (Maybe a) -> k -> P.Sem r (Maybe a)
handleAtomicLookup (Serialize encode decode encBytes) tryIfMissing key =
  K.wrapPrefix ("AtomicCache.handleAtomicLookup (key=" <> (T.pack $ show key) <> ")") $ do
    fromCache <- cacheLookup key
    case fromCache of
      Right ct -> do
        let nBytes = encBytes ct
        K.logLE K.Diagnostic $ "key=" <> (T.pack $ show key) <> ": Retrieved " <> (T.pack $ show nBytes) <> " bytes from cache. Deserializing..."
        fmap Just $ decode ct
      Left emptyTMV -> do
        K.logLE K.Diagnostic $ "key=" <> (T.pack $ show key) <> ": Trying to make from given action." 
        ma <- tryIfMissing
        case ma of
          Nothing -> do
            K.logLE K.Diagnostic $ "key=" <> (T.pack $ show key) <> ": Making failed."
            P.embed $ C.atomically $ C.putTMVar emptyTMV Nothing
            cacheUpdate key Nothing
            return Nothing
          Just a -> do
            K.logLE K.Diagnostic $ "key=" <> (T.pack $ show key) <> ": Making/Encoding..."
            (ct', a') <- encode a -- a' is the "already computed" version of a
            let nBytes = encBytes ct'
            K.logLE K.Diagnostic $ "key=" <> (T.pack $ show key) <> ": serialized to " <> (T.pack $ show nBytes) <> " bytes."
            K.logLE K.Diagnostic "Updating TMVar..."          
            P.embed $ C.atomically $ C.putTMVar emptyTMV (Just ct') -- for any thread waiting on the TMVar
            K.logLE K.Diagnostic $ "Updating cache..."          
            cacheUpdate key (Just ct')
            K.logLE K.Diagnostic $ "Finished making and updating."          
            return $ Just a'
  

-- | Combinator to combine the action of retrieving from cache and deserializing
-- | throws if item not found or any other error during retrieval
retrieveAndDecode
  :: (P.Member (AtomicCache k ct) r
     , P.Member (P.Embed IO) r
     , P.MemberWithError (P.Error CacheError) r
     , K.LogWithPrefixesLE r
     , Show k
     )
  => Serialize r a ct
  -> k
  -> P.Sem r a
retrieveAndDecode s k = K.wrapPrefix ("AtomicCache.retrieveAndDecode (key=" <> (T.pack $ show k) <> ")") $ do
  fromCache <- handleAtomicLookup s (return Nothing) k
  case fromCache of
    Nothing -> P.throw $ ItemNotFoundError $ "No item found in cache for key=" <> (T.pack $ show k) <> "."
    Just x -> return x
{-# INLINEABLE retrieveAndDecode #-}

-- | Combinator to combine the action of retrieving from cache and deserializing
-- | Returns @Nothing@ if item not found and throws on any other error.
lookupAndDecode
  :: forall k a ct r
   . ( P.Member (AtomicCache k ct) r
     , K.LogWithPrefixesLE r
     , P.Member (P.Embed IO) r
     , P.MemberWithError (P.Error CacheError) r
     , Show k
     )
  => Serialize r a ct
  -> k
  -> P.Sem r (Maybe a)
lookupAndDecode s k = K.wrapPrefix ("AtomicCache.lookupAndDecode (key=" <> (T.pack $ show k) <> ")") $ handleAtomicLookup s (return Nothing) k 
{-# INLINEABLE lookupAndDecode #-}

retrieveOrMake
  :: ( P.Member (AtomicCache k ct) r
     , K.LogWithPrefixesLE r
     , P.Member (P.Embed IO) r
     , P.MemberWithError (P.Error CacheError) r
     , Show k
     )
  => Serialize r a ct
  -> k
  -> P.Sem r a
  -> P.Sem r a
retrieveOrMake s key makeAction = K.wrapPrefix ("retrieveOrMake (key=" <> (T.pack $ show key) <> ")") $ do
  let makeIfMissing = K.wrapPrefix "retrieveOrMake.makeIfMissing" $ do
        K.logLE K.Diagnostic $ "Item (at key=" <> (T.pack $ show key) <> ") not found in cache. Making..."
        fmap Just makeAction
  fromCache <- handleAtomicLookup s makeIfMissing key
  case fromCache of
    Just x -> return x
    Nothing -> P.throw $ OtherCacheError $ "retrieveOrMake returned with Nothing.  Which should be impossible."

-- | Combinator for clearing the cache at a given key
clear :: P.Member (Cache k ct h) r => k -> P.Sem r ()
clear k = cacheUpdate k Nothing
{-# INLINEABLE clear #-}

-- structure for in-memory cache
-- outer TVar so only one thread can get the inner TMVar at a time
-- TMVar so we can block if mulitple threads are trying to read or update
-- Maybe inside so we can notify waiting threads that whatever they were waiting on
-- to fill the TMVar failed.
type AtomicMemCache k v = C.TVar (M.Map k (C.TMVar (Maybe v)))
type AtomicCache k ct = Cache k ct (C.TMVar (Maybe ct)) 
type SimpleCache k ct = Cache k ct ()

-- interpret via MemCache
atomicMemLookup :: (Ord k
                   , Show k
                   , P.Member (P.Embed IO) r
                   , K.LogWithPrefixesLE r
                   )
              => AtomicMemCache k ct
              -> k
              -> P.Sem r (Either (C.TMVar (Maybe ct)) ct) -- we either return the value or a tvar to be filled
atomicMemLookup cache key = K.wrapPrefix "atomicMemLookup" $ do
  K.logLE K.Diagnostic $ "key=" <> (T.pack $ show key) <> ": Called."
  P.embed $ C.atomically $ do
    mv <- (C.readTVar cache >>= fmap join . traverse C.readTMVar . M.lookup key)
    case mv of
      Just v -> return $ Right v
      Nothing -> do
        newTMV <- C.newEmptyTMVar
        C.modifyTVar cache (M.insert key newTMV)
        return $ Left newTMV
{-# INLINEABLE atomicMemLookup #-}

data MemUpdateAction = Deleted | Replaced | Filled deriving (Show)

atomicMemUpdate :: (Ord k
                   , Show k
                   , P.Member (P.Embed IO) r
                   , K.LogWithPrefixesLE r
                   )
                => AtomicMemCache k ct
                -> k
                -> Maybe ct
                -> P.Sem r ()
atomicMemUpdate cache key mct =
  K.wrapPrefix "atomicMemUpdate" $ do
  let keyText = "key=" <> (T.pack $ show key) <> ": "
  K.logLE K.Diagnostic $ keyText <> "called."
  updateAction <- case mct of
    Nothing -> (P.embed $ C.atomically $ C.modifyTVar cache (M.delete key)) >> return Deleted
    Just ct -> P.embed $ C.atomically $ do
      m <- C.readTVar cache
      case M.lookup key m of
        Nothing -> do
          newTMV <- C.newTMVar (Just ct)
          C.modifyTVar cache (M.insert key newTMV)
          return Filled
        Just tmvM -> do
          wasEmptyTMVar <- C.tryPutTMVar tmvM (Just ct)
          if wasEmptyTMVar
            then return Filled
            else (C.swapTMVar tmvM (Just ct)) >> return Replaced
  case updateAction of
    Deleted -> K.logLE K.Diagnostic $ keyText <> "deleted"
    Replaced -> K.logLE K.Diagnostic $ keyText <> "replaced"
    Filled -> K.logLE K.Diagnostic $ keyText <> "filled"
{-# INLINEABLE atomicMemUpdate #-}

runAtomicInMemoryCache :: (Ord k
                          , Show k
                          , P.Member (P.Embed IO) r
                          , K.LogWithPrefixesLE r
                          )
                       => AtomicMemCache k ct
                       -> P.InterpreterFor (AtomicCache k ct) r
runAtomicInMemoryCache cache =
  P.interpret $ \case
    CacheLookup key -> atomicMemLookup cache key
    CacheUpdate key mct -> atomicMemUpdate cache key mct
{-# INLINEABLE runAtomicInMemoryCache #-}


-- Backed by Another Cache
-- lookup is the hard case.  If we don't find it, we want to check the backup cache
-- and fill in this cache from there, if possible
atomicMemLookupB :: (Ord k
                    , P.Members '[P.Embed IO, SimpleCache k ct] r
                    , K.LogWithPrefixesLE r
                    , Show k
                    )
                 =>  AtomicMemCache k ct
                 -> k
                 -> P.Sem r (Either (C.TMVar (Maybe ct)) ct)
atomicMemLookupB cache key = K.wrapPrefix "atomicMemLookupB" $ do
  let keyText = "key=" <> (T.pack $ show key) <> ": "
  K.logLE K.Diagnostic $ keyText <> "checking in mem cache..."
  x <- P.embed $ C.atomically $ do
    mTMV <- M.lookup key <$> C.readTVar cache
    case mTMV of
      Just tmv -> do
        mv <- C.takeTMVar tmv  
        case mv of
          Just ct -> do -- in cache with value
            C.putTMVar tmv (Just ct)
            return $ Right ct
          Nothing -> return $ Left tmv  -- in cache but set to Nothing
      Nothing -> do -- not found
        newTMV <- C.newEmptyTMVar
        C.modifyTVar cache (M.insert key newTMV)
        return $ Left newTMV
  case x of
    Right ct -> K.logLE K.Diagnostic (keyText <> "found.") >> return (Right ct)
    Left emptyTMV -> do
      K.logLE K.Diagnostic (keyText <> "not found.  Holding empty TMVar. Checking backup cache...")
      inOtherM <- cacheLookup key      
      case inOtherM of
        Left () -> K.logLE K.Diagnostic (keyText <> "not found in backup cache.  Returning empty TMVar.") >> return (Left emptyTMV)
        Right ct -> do
          K.logLE K.Diagnostic (keyText <> "Found in backup cache.  Putting in TMVar.")
          P.embed $ C.atomically $ C.putTMVar emptyTMV (Just ct)
          K.logLE K.Diagnostic (keyText <> "Returning")
          return $ Right ct
{-# INLINEABLE atomicMemLookupB #-}
            
atomicMemUpdateB ::  (Ord k
                     , Show k
                     , K.LogWithPrefixesLE r
                     , P.Members '[P.Embed IO, SimpleCache k ct] r)
                 => AtomicMemCache k ct
                 -> k
                 -> Maybe ct
                 -> P.Sem r ()
atomicMemUpdateB cache key mct = K.wrapPrefix "atomicMemUpdateB" $ do
  let keyText = "key=" <> (T.pack $ show key) <> ": "
  K.logLE K.Diagnostic $ keyText <> "Calling atomicMemUpdate"
  atomicMemUpdate cache key mct
  K.logLE K.Diagnostic $ keyText <> "Calling cacheUpdate in backup cache."
  cacheUpdate key mct
{-# INLINEABLE atomicMemUpdateB #-}

runBackedAtomicInMemoryCache :: (Ord k
                                , Show k
                                , K.LogWithPrefixesLE r
                                , P.Members '[P.Embed IO, SimpleCache k ct] r
                                )
                             => AtomicMemCache k ct
                             -> P.InterpreterFor (AtomicCache k ct) r
runBackedAtomicInMemoryCache cache =
  P.interpret $ \case
    CacheLookup k -> atomicMemLookupB cache k
    CacheUpdate k mct -> atomicMemUpdateB cache k mct
{-# INLINEABLE runBackedAtomicInMemoryCache #-}

backedAtomicInMemoryCache :: (Ord k
                             , Show k
                             , P.Member (P.Embed IO) r
                             , K.LogWithPrefixesLE r
                             )
                          => AtomicMemCache k ct
                          -> P.Sem ((AtomicCache k ct) ': r) a
                          -> P.Sem ((SimpleCache k ct) ': r) a
backedAtomicInMemoryCache cache =
  P.reinterpret $ \case
    CacheLookup k -> atomicMemLookupB cache k
    CacheUpdate k mct -> atomicMemUpdateB cache k mct    
{-# INLINEABLE backedAtomicInMemoryCache #-} 


runPersistenceBackedAtomicInMemoryCache :: (Ord k
                                           , Show k
                                           , P.Member (P.Embed IO) r
                                           , P.MemberWithError (P.Error CacheError) r
                                           , K.LogWithPrefixesLE r
                                           )
                                        => P.InterpreterFor (SimpleCache k ct) r -- persistence layer interpreter
                                        -> AtomicMemCache k ct
                                        -> P.InterpreterFor (AtomicCache k ct) r
runPersistenceBackedAtomicInMemoryCache runPersistentCache cache = runPersistentCache . backedAtomicInMemoryCache cache
{-# INLINEABLE runPersistenceBackedAtomicInMemoryCache #-}


runPersistenceBackedAtomicInMemoryCache' :: (Ord k
                                            , Show k
                                            , P.Member (P.Embed IO) r
                                            , P.MemberWithError (P.Error CacheError) r
                                            , K.LogWithPrefixesLE r
                                            )
                                        => P.InterpreterFor (SimpleCache k ct) r
                                        -> P.InterpreterFor (AtomicCache k ct) r
runPersistenceBackedAtomicInMemoryCache' runPersistentCache x = do
  cache <- P.embed $ C.atomically $ C.newTVar mempty
  runPersistenceBackedAtomicInMemoryCache runPersistentCache cache x 



persistAsByteStreamly
  :: (Show k, P.Member (P.Embed IO) r, P.MemberWithError (P.Error CacheError) r, K.LogWithPrefixesLE r)
  => (k -> FilePath)
  -> P.InterpreterFor (SimpleCache k (Streamly.SerialT Identity Word.Word8)) r
persistAsByteStreamly keyToFilePath =
  P.interpret $ \case
    CacheLookup k -> K.wrapPrefix "persistAsByteStreamly.CacheLookup" $ do
      let filePath = keyToFilePath k
      K.logLE K.Diagnostic $ "Attempting to read serialization from disk."
      rethrowIOErrorAsCacheError $ fileNotFoundToEither $ sequenceStreamly $ Streamly.File.toBytes filePath --System.withBinaryFile filePath System.ReadMode readFromHandle
    CacheUpdate k mct -> K.wrapPrefix "persistAsByteStreamly.CacheUpdate" $ do
      let keyText = "key=" <> (T.pack $ show k) <> ": "
      case mct of
        Nothing -> do
          K.logLE K.Diagnostic $ keyText <> "called with Nothing. Deleting file."
          rethrowIOErrorAsCacheError $ System.removeFile (keyToFilePath k)
        Just ct -> do
          K.logLE K.Diagnostic $ keyText <> "called with content. Writing file."
          let filePath     = (keyToFilePath k)
              (dirPath, _) = T.breakOnEnd "/" (T.pack filePath)
          _ <- createDirIfNecessary dirPath
          K.logLE K.Diagnostic $ keyText <> "Writing serialization to disk."
          let sLength = runIdentity $ Streamly.length ct
          K.logLE K.Diagnostic $ keyText <> "Writing " <> (T.pack $ show sLength) <> " bytes to disk." 
          rethrowIOErrorAsCacheError $ (System.withBinaryFile filePath System.WriteMode $ writeToHandle ct) -- maybe we should do this in another thread?
  where
    sequenceStreamly :: Monad m => Streamly.SerialT m Word.Word8 -> m (Streamly.SerialT Identity Word.Word8)
    sequenceStreamly = fmap Streamly.fromList . Streamly.toList
    streamlyRaise :: Monad m => Streamly.SerialT Identity Word.Word8 -> Streamly.SerialT m Word.Word8
    streamlyRaise = Streamly.fromList . runIdentity . Streamly.toList
--    readFromHandle h = sequenceStreamly $ Streamly.unfold Streamly.Handle.read h
    writeToHandle bs h = Streamly.fold (Streamly.Handle.write h) $ streamlyRaise bs
{-# INLINEABLE persistAsByteStreamly #-}

persistAsByteArray
  :: (Show k, P.Member (P.Embed IO) r, P.MemberWithError (P.Error CacheError) r, K.LogWithPrefixesLE r)
  => (k -> FilePath)
  -> P.InterpreterFor (SimpleCache k (Streamly.Array.Array Word.Word8)) r
persistAsByteArray keyToFilePath =
  P.interpret $ \case
    CacheLookup k -> K.wrapPrefix "persistAsByteArray.CacheLookup" $ do
      let filePath = keyToFilePath k
      K.logLE K.Diagnostic $ "Reading serialization from disk."
      rethrowIOErrorAsCacheError $ fileNotFoundToEither $ Streamly.Array.fromStream $ Streamly.File.toBytes filePath
    CacheUpdate k mct -> K.wrapPrefix "persistAsByteStreamly.CacheUpdate" $ do
      let keyText = "key=" <> (T.pack $ show k) <> ": "
      case mct of
        Nothing -> do
           K.logLE K.Diagnostic $ keyText <> "called with Nothing. Deleting file."
           rethrowIOErrorAsCacheError $ System.removeFile (keyToFilePath k)
        Just ct -> do
          K.logLE K.Diagnostic $ keyText <> "called with content. Writing file."
          let filePath     = (keyToFilePath k)
              (dirPath, _) = T.breakOnEnd "/" (T.pack filePath)
          _ <- createDirIfNecessary dirPath
          K.logLE K.Diagnostic $ "Writing serialization to disk."
          K.logLE K.Diagnostic $ keyText <> "Writing " <> (T.pack $ show $ Streamly.Array.length ct) <> " bytes to disk." 
          rethrowIOErrorAsCacheError $ Streamly.File.writeArray filePath ct
{-# INLINEABLE persistAsByteArray #-}


persistAsStrictByteString
  :: (P.Members '[P.Embed IO] r, P.MemberWithError (P.Error CacheError) r, K.LogWithPrefixesLE r)
  => (k -> FilePath)
  -> P.InterpreterFor (SimpleCache k BS.ByteString) r
persistAsStrictByteString keyToFilePath =
  P.interpret $ \case
    CacheLookup k -> do
      K.logLE K.Diagnostic $ "Reading serialization from disk."
      rethrowIOErrorAsCacheError $ fileNotFoundToEither $ BS.readFile (keyToFilePath k)
    CacheUpdate k mct -> case mct of
      Nothing -> rethrowIOErrorAsCacheError $ System.removeFile (keyToFilePath k)
      Just ct -> do
        let filePath     = (keyToFilePath k)
            (dirPath, _) = T.breakOnEnd "/" (T.pack filePath)
        _ <- createDirIfNecessary dirPath
        K.logLE K.Diagnostic $ "Writing serialization to disk."
        rethrowIOErrorAsCacheError $ BS.writeFile filePath ct  -- maybe we should do this in another thread?
{-# INLINEABLE persistAsStrictByteString #-}

-- | Persist functions for disk-based persistence with a lazy ByteString interface on the serialization side
persistAsByteString
  :: (P.Members '[P.Embed IO] r, P.MemberWithError (P.Error CacheError) r, K.LogWithPrefixesLE r)
  => (k -> FilePath)
  -> P.InterpreterFor (SimpleCache k BL.ByteString) r
persistAsByteString keyToFilePath =
  P.interpret $ \case
    CacheLookup k -> do
      K.logLE K.Diagnostic $ "Reading serialization from disk."
      rethrowIOErrorAsCacheError $ fileNotFoundToEither $ BL.readFile (keyToFilePath k)
    CacheUpdate k mct -> case mct of
      Nothing -> rethrowIOErrorAsCacheError $ System.removeFile (keyToFilePath k)
      Just ct -> do
        let filePath     = (keyToFilePath k)
            (dirPath, _) = T.breakOnEnd "/" (T.pack filePath)
        _ <- createDirIfNecessary dirPath
        K.logLE K.Diagnostic $ "Writing serialization to disk."
        rethrowIOErrorAsCacheError $ BL.writeFile filePath ct  -- maybe we should do this in another thread?


createDirIfNecessary
  :: (P.Members '[P.Embed IO] r, K.LogWithPrefixesLE r)
  => T.Text
  -> K.Sem r ()
createDirIfNecessary dir = K.wrapPrefix "createDirIfNecessary" $ do
  K.logLE K.Diagnostic $ "Checking if cache path (\"" <> dir <> "\") exists."
  existsB <- P.embed $ (System.doesDirectoryExist (T.unpack dir))
  case existsB of
    True -> do
      K.logLE K.Diagnostic $ "\"" <> dir <> "\" exists."
      return ()
    False -> do
      K.logLE K.Info
        $  "Cache directory (\""
        <> dir
        <> "\") not found. Atttempting to create."
      P.embed
        $ System.createDirectoryIfMissing True (T.unpack dir)
{-# INLINEABLE createDirIfNecessary #-}


fileNotFoundToEither :: IO a -> IO (Either () a)
fileNotFoundToEither x = (fmap Right x) `Exception.catch` f where
  f :: Exception.IOException -> IO (Either () a)
  f e = if IO.Error.isDoesNotExistError e then return (Left ()) else Exception.throw e 
{-# INLINEABLE fileNotFoundToEither #-}

rethrowIOErrorAsCacheError :: (P.Member (P.Embed IO) r, P.MemberWithError (P.Error CacheError) r) => IO a -> P.Sem r a
rethrowIOErrorAsCacheError x = P.fromExceptionVia (\(e :: IO.Error.IOError) -> PersistError $ "IOError: " <> (T.pack $ show e)) x



