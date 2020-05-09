{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}
{-|
Module      : Knit.Report.Cache
Description : Combinators for using the AtomicCache effect
Copyright   : (c) Adam Conner-Sax 2019
License     : BSD-3-Clause
Maintainer  : adam_conner_sax@yahoo.com
Stability   : experimental

This module adds types, combinators and knit functions for using knit-haskell with the AtomicCache effect. 

<https://github.com/adamConnerSax/knit-haskell/tree/master/examples Examples> are available, and might be useful for seeing how all this works.
-}
module Knit.Report.Cache
  (
    -- * Types
    KnitCache
    -- * Cache Combinators
  , store
  , retrieve
  , retrieveOrMake
  , retrieveOrMakeTransformed
  , storeStream
  , retrieveStream
  , retrieveOrMakeStream
  , retrieveOrMakeTransformedStream
  , clear
  )
where

--import qualified Knit.Report.EffectStack       as K

import qualified Knit.Effect.AtomicCache       as C
import           Knit.Effect.AtomicCache        (clear)
import qualified Knit.Effect.Logger            as K

import qualified Control.Monad.Catch as Exceptions (SomeException)

import qualified Data.ByteString               as BS
import qualified Data.ByteString.Lazy          as BL
import           Data.Functor.Identity          (Identity(..))
import qualified Data.Text                     as T
import qualified Data.Serialize                as S
import qualified Data.Word                     as Word

import qualified Polysemy                      as P
import qualified Polysemy.Error                as P
import qualified Polysemy.ConstraintAbsorber.MonadCatch as Polysemy.MonadCatch

import qualified Streamly                      as Streamly
import qualified Streamly.Prelude              as Streamly
import qualified Streamly.Internal.Prelude              as Streamly
import qualified Streamly.Memory.Array         as Streamly.Array
import qualified Streamly.Cereal               as Streamly.Cereal

type KnitCache = C.AtomicCache T.Text CacheData

type CacheData = Streamly.Array.Array Word.Word8

knitSerialize :: ( S.Serialize a
                 , P.Member (P.Embed IO) r
                 , P.MemberWithError (P.Error C.CacheError) r
                 )
              => S.Serialize r a CacheData
knitSerialize = cerealArray
{-# INLINEABLE knitSerialize #-}


knitSerializeStream :: (S.Serialize a
                       , P.Member (P.Embed IO) r                
                       , P.MemberWithError (P.Error Exceptions.SomeException) r
                       , P.MemberWithError (P.Error C.CacheError) r
                       )
                       => S.Serialize r (Streamly.SerialT (K.Sem r) a) CacheData
knitSerializeStream = cerealStreamArray
{-# INLINEABLE knitSerializeStream #-}

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
{-# INLINEABLE mapLeft #-}

cerealStrict :: (S.Serialize a, P.MemberWithError (P.Error C.CacheError) r)
             => C.Serialize r a BS.ByteString
cerealStrict = C.Serialize 
  (return . S.encode)
  (P.fromEither @C.CacheError . mapLeft (C.DeSerializationError . T.pack) . S.decode)
  (fromIntegral . BS.length)
{-# INLINEABLE cerealStrict #-}

cereal :: (S.Serialize a, P.MemberWithError (P.Error C.CacheError) r)
       => C.Serialize r a BL.ByteString
cereal = C.Serialize
  (return . S.encodeLazy)
  (P.fromEither . mapLeft (C.DeSerializationError . T.pack) . S.decodeLazy)
  BL.length
{-# INLINEABLE cereal #-}

cerealStreamly :: (S.Serialize a
                  , P.Member (P.Embed IO) r
                  , P.MemberWithError (P.Error C.CacheError) r
                  ) => C.Serialize r a (Streamly.SerialT Identity Word.Word8)
cerealStreamly = C.Serialize
  (return . Streamly.Cereal.encodeStreamly)
  (P.fromEither . mapLeft C.DeSerializationError . runIdentity . Streamly.Cereal.decodeStreamly)
  (fromIntegral . runIdentity . Streamly.length)
{-# INLINEABLE cerealStreamly #-}


cerealStream :: (S.Serialize a
                , P.Member (P.Embed IO) r                
                , P.MemberWithError (P.Error Exceptions.SomeException) r
                , P.MemberWithError (P.Error C.CacheError) r
                )
             => C.Serialize r (Streamly.SerialT (P.Sem r) a) (Streamly.SerialT Identity Word.Word8)
cerealStream = C.Serialize
  (fmap Streamly.fromList . Streamly.toList . Streamly.Cereal.encodeStream)
  (\x -> Polysemy.MonadCatch.absorbMonadCatch $ return $ Streamly.Cereal.decodeStream $ Streamly.generally x)
  (fromIntegral . runIdentity . Streamly.length)




-- | Store an @a@ (serialized to a strict @ByteString@) at key k. Throw PandocIOError on IOError.
store
  :: ( P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , S.Serialize a
     )
  => T.Text
  -> a
  -> P.Sem r ()
store k a = K.wrapPrefix "Knit.store" $ do
  K.logLE K.Diagnostic $ "Called with k=" <> k
  C.encodeAndStore cerealStreamly k a
{-# INLINEABLE store #-}

-- | Retrieve an a from the store at key k. Throw if not found or IOError
retrieve
  :: (P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     ,  K.LogWithPrefixesLE r
     , S.Serialize a)
  => T.Text
  -> P.Sem r a
retrieve k =  K.wrapPrefix "Knit.retrieve" $ C.retrieveAndDecode knitSerialize k
{-# INLINEABLE retrieve #-}

-- | Retrieve an a from the store at key k.
-- If retrieve fails then perform the action and store the resulting a at key k. 
retrieveOrMake
  :: forall a r
   . ( P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , S.Serialize a
     )
  => T.Text
  -> P.Sem r a
  -> P.Sem r a
retrieveOrMake k toMake = K.wrapPrefix "Knit.retrieveOrMake" $ C.retrieveOrMake knitSerialize k toMake
{-# INLINEABLE retrieveOrMake #-}

retrieveOrMakeTransformed
  :: forall a b r
   . ( P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , S.Serialize b
     )
  => (a -> b)
  -> (b -> a)
  -> T.Text
  -> P.Sem r a
  -> P.Sem r a
retrieveOrMakeTransformed toSerializable fromSerializable k toMake =
  K.wrapPrefix "Knit.retrieveOrMakeTransformed" $ 
  fmap fromSerializable $ retrieveOrMake k (fmap toSerializable toMake)
{-# INLINEABLE retrieveOrMakeTransformed #-}

--
-- | Store an @a@ (serialized to a strict @ByteString@) at key k. Throw PandocIOError on IOError.
storeStream
  :: ( P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     , P.MemberWithError (P.Error Exceptions.SomeException) r
     , K.LogWithPrefixesLE r
     , S.Serialize a
     )
  => T.Text
  -> Streamly.SerialT (P.Sem r) a
  -> P.Sem r ()
storeStream k aS = K.wrapPrefix "Knit.storeStream" $ do
  K.logLE K.Diagnostic $ "Called with k=" <> k
  C.encodeAndStore knitSerializeStream k aS
{-# INLINEABLE storeStream #-}


-- | Retrieve an a from the store at key k. Throw if not found or IOError
retrieveStream
  :: (P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , P.MemberWithError (P.Error Exceptions.SomeException) r
     , S.Serialize a)
  => T.Text
  -> Streamly.SerialT (P.Sem r) a
retrieveStream k =  Streamly.concatM $ K.wrapPrefix "Knit.retrieve" $ C.retrieveAndDecode knitSerializeStream k
{-# INLINEABLE retrieveStream #-}


-- | Retrieve an a from the store at key k.
-- If retrieve fails then perform the action and store the resulting a at key k. 
retrieveOrMakeStream
  :: forall a r
   . ( P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , P.MemberWithError (P.Error Exceptions.SomeException) r
     , S.Serialize a
     )
  => T.Text
  -> Streamly.SerialT (P.Sem r) a
  -> Streamly.SerialT (P.Sem r) a
retrieveOrMakeStream k toMake = Streamly.concatM $ K.wrapPrefix "Knit.retrieveOrMake" $ C.retrieveOrMake knitSerializeStream k (return toMake)
{-# INLINEABLE retrieveOrMakeStream #-}

--  This one needs a "wrapPrefix".  But how, in stream land?
retrieveOrMakeTransformedStream
  :: forall a b r
   . ( P.Members '[KnitCache, P.Error C.CacheError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , P.MemberWithError (P.Error Exceptions.SomeException) r
     , S.Serialize b
     )
  => (a -> b)
  -> (b -> a)
  -> T.Text
  -> Streamly.SerialT (P.Sem r) a
  -> Streamly.SerialT (P.Sem r) a
retrieveOrMakeTransformedStream toSerializable fromSerializable k toMake = 
  Streamly.hoist (K.wrapPrefix "Knit.retrieveOrMakeTransformedStream")
  $ Streamly.map fromSerializable
  $ retrieveOrMakeStream k (Streamly.map toSerializable toMake)
{-# INLINEABLE retrieveOrMakeTransformedStream #-}


{-
-- | Retrieve an a from the store at key k. Throw if not found or IOError
retrieveStream
  :: (P.Members '[KnitCache, P.Error PandocError, P.Embed IO] r, S.Serialize a)
  => T.Text
  -> Streamly.SerialT (P.Sem r) a
retrieveStream k = P.mapError ioErrorToPandocError $ C.retrieve cerealStream k
{-# INLINEABLE retrieve #-}

-- | Retrieve an a from the store at key k.
-- If retrieve fails then perform the action and store the resulting a at key k. 
retrieveOrMake
  :: forall a r
   . ( P.Members '[KnitCache, P.Error PandocError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , S.Serialize a
     )
  => T.Text
  -> P.Sem r a
  -> P.Sem r a
retrieveOrMake k toMake = K.wrapPrefix "knitRetrieveOrMake" $ do
  ma <- C.retrieveMaybe cerealStreamly k
  case ma of
    Nothing -> do
      K.logLE K.Diagnostic $ k <> " not found in cache. Making..."
      a <- toMake
      store k a
      K.logLE K.Diagnostic $ "Asset Stored."
      return a
    Just a -> do
      K.logLE K.Diagnostic $ k <> " found in cache."
      return a
{-# INLINEABLE retrieveOrMake #-}

retrieveOrMakeTransformed
  :: forall a b r
   . ( P.Members '[KnitCache, P.Error PandocError, P.Embed IO] r
     , K.LogWithPrefixesLE r
     , S.Serialize b
     )
  => (a -> b)
  -> (b -> a)
  -> T.Text
  -> P.Sem r a
  -> P.Sem r a
retrieveOrMakeTransformed toSerializable fromSerializable k toMake =
  fmap fromSerializable $ retrieveOrMake k (fmap toSerializable toMake)
{-# INLINEABLE retrieveOrMakeTransformed #-}
-}
{-
-- | Clear the @b@ stored at key k.
clear :: K.KnitEffects r => T.Text -> P.Sem r ()
clear k = P.mapError ioErrorToPandocError $ C.clear k
{-# INLINEABLE clear #-}

ioErrorToPandocError :: IE.IOError -> PandocError
ioErrorToPandocError e = PandocIOError (K.textToPandocText $ ("IOError: " <> (T.pack $ show e)) e
{-# INLINEABLE ioErrorToPandocError #-}
-}
