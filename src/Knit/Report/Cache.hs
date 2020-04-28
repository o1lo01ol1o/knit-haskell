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
  , clear
  )
where

import qualified Knit.Report.EffectStack       as K

import qualified Knit.Effect.AtomicCache       as C
import qualified Knit.Effect.Logger            as K
import qualified Knit.Effect.PandocMonad       as K
                                                ( textToPandocText )

import qualified Data.ByteString               as BS
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Text                     as T
import qualified Data.Serialize                as S

import           Text.Pandoc.Error              ( PandocError
                                                  ( PandocSomeError
                                                  , PandocIOError
                                                  )
                                                )
import qualified System.IO.Error               as IE

import qualified Polysemy                      as P
import qualified Polysemy.Error                as P

type KnitCache = C.AtomicCache IE.IOError T.Text BL.ByteString BS.ByteString

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right

cerealStrict :: S.Serialize a => C.Serialize PandocError a BS.ByteString BS.ByteString
cerealStrict = C.Serialize
  S.encode
  (mapLeft (PandocSomeError . K.textToPandocText . T.pack) . S.decode)

cereal :: S.Serialize a => C.Serialize PandocError a BL.ByteString BS.ByteString
cereal = C.Serialize
  S.encodeLazy
  (mapLeft (PandocSomeError . K.textToPandocText . T.pack) . S.decode)



-- | Store an @a@ (serialized to a strict @ByteString@) at key k. Throw PandocIOError on IOError.
store
  :: ( P.Members '[KnitCache, P.Error PandocError] r
     , K.LogWithPrefixesLE r
     , S.Serialize a
     )
  => T.Text
  -> a
  -> P.Sem r ()
store k a = K.wrapPrefix "knitStore" $ do
  K.logLE K.Diagnostic $ "Called with k=" <> k
  P.mapError ioErrorToPandocError $ C.store cereal k a

-- | Retrieve an a from the store at key k. Throw if not found or IOError
retrieve
  :: (P.Members '[KnitCache, P.Error PandocError] r, S.Serialize a)
  => T.Text
  -> P.Sem r a
retrieve k = P.mapError ioErrorToPandocError $ C.retrieve cereal k

-- | Retrieve an a from the store at key k.
-- If retrieve fails then perform the action and store the resulting a at key k. 
retrieveOrMake
  :: forall a r
   . ( P.Members '[KnitCache, P.Error PandocError] r
     , K.LogWithPrefixesLE r
     , S.Serialize a
     )
  => T.Text
  -> P.Sem r a
  -> P.Sem r a
retrieveOrMake k toMake = K.wrapPrefix "knitRetrieveOrMake" $ do
  ma <- C.retrieveMaybe cereal k
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

retrieveOrMakeTransformed
  :: forall a b r
   . ( P.Members '[KnitCache, P.Error PandocError] r
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

-- | Clear the @b@ stored at key k.
clear :: K.KnitEffects r => T.Text -> P.Sem r ()
clear k = P.mapError ioErrorToPandocError $ C.clear k


ioErrorToPandocError :: IE.IOError -> PandocError
ioErrorToPandocError e = PandocIOError (K.textToPandocText $ T.pack $ show e) e
