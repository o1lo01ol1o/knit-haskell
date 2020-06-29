{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}
{-|
Module      : Knit.Report.EffectStack
Description : Knit effects stack, interpreters and configuration for Html reports
Copyright   : (c) Adam Conner-Sax 2019
License     : BSD-3-Clause
Maintainer  : adam_conner_sax@yahoo.com
Stability   : experimental

This module contains the core effect stack, interpreter and configurations for building Html reports.

<https://github.com/adamConnerSax/knit-haskell/tree/master/examples Examples> are available, and might be useful for seeing how all this works.
-}
module Knit.Report.EffectStack
  (
    -- * Configuraiton
    KnitConfig(..)
  , defaultKnitConfig
    -- * Knit documents
  , knitHtml
  , knitHtmls
    -- * helpers
  , liftKnit
  -- * Constraints for knit-haskell actions (see examples)
  , KnitEffects
  , KnitEffectStack
  , KnitOne
  , KnitMany
  , KnitBase
  , DefaultEffects
  , DefaultKnitOne
  , DefaultKnitMany
  )
where

import           Control.Monad.Except           ( MonadIO )
import qualified Control.Monad.Catch as Exceptions (SomeException, displayException) 
import qualified Data.Map                      as M
import           Data.Maybe (fromMaybe)
import qualified Data.Text                     as T
import qualified Data.Serialize                as S
import qualified Data.Text.Lazy                as TL
import qualified Polysemy                      as P
import qualified Polysemy.Async                as P
import qualified Polysemy.Error                as PE
import qualified Polysemy.IO                   as PI
import qualified System.IO.Error               as IE


import qualified Text.Pandoc                   as PA
import qualified Text.Blaze.Html.Renderer.Text as BH



import qualified Knit.Report.Output            as KO
import qualified Knit.Report.Output.Html       as KO
import qualified Knit.Effect.Docs              as KD
import qualified Knit.Effect.Pandoc            as KP
import qualified Knit.Effect.PandocMonad       as KPM
import qualified Knit.Effect.Logger            as KLog
import qualified Knit.Effect.UnusedId          as KUI
import qualified Knit.Effect.AtomicCache       as KC
import qualified Knit.Effect.Serialize         as KS
import qualified Knit.Effect.Environment       as KE

{- |
Parameters for knitting. If possible, create this via, e.g., 

@
myConfig = (defaultKnitConfig Nothing) { cacheDir = "myCacheDir", pandocWriterConfig = myConfig }
@
so that your code will still compile if parameters are added to this structure.

NB: the type parameters of this configuration specify the cache types:

- @c :: Type -> Constraint@, where @c a@ is the constraint to be satisfied for serializable @a@.
- @k :: Type@, is the key type of the cache.
- @ct :: Type@, is the value type held in the in-memory cache.

The @serializeDict@ field holds functions for encoding (@forall a. c a=> a -> ct@)
and decoding (@forall a. c a => ct -> Either SerializationError a).

The @persistCache@ field holds an interpreter for the persistence layer of
the cache. See 'Knit.AtomicCache' for examples of persistennce layers.

If you want to use a different serializer ("binary" or "store") and/or a different type to hold cached
values in-memory, you can set these fields accordingly.

-}
data KnitConfig c k ct = KnitConfig { outerLogPrefix :: Maybe T.Text
                                    , logIf :: KLog.LogSeverity -> Bool
                                    , pandocWriterConfig :: KO.PandocWriterConfig
                                    , serializeDict :: KS.SerializeDict c ct
                                    , persistCache :: forall r. (P.Member (P.Embed IO) r
                                                                , P.MemberWithError (PE.Error KC.CacheError) r
                                                                , KLog.LogWithPrefixesLE r)
                                                      => P.InterpreterFor (KC.Cache k ct) r
                                    }

-- | Sensible defaults for a knit configuration.
defaultKnitConfig :: Maybe T.Text -> KnitConfig S.Serialize T.Text KS.DefaultCacheData 
defaultKnitConfig cacheDirM =
  let cacheDir = fromMaybe ".knit-haskell-cache" cacheDirM
  in KnitConfig
     (Just "knit-haskell")
     KLog.nonDiagnostic
     (KO.PandocWriterConfig Nothing M.empty id)
     KS.cerealStreamlyDict
     (KC.persistAsByteArray (\t -> T.unpack (cacheDir <> "/" <> t)))
{-# INLINEABLE defaultKnitConfig #-}                               

-- | Create multiple HTML docs (as Text) from the named sets of pandoc fragments.
-- In use, you may need a type-application to specify @m@.
-- This allows use of any underlying monad to handle the Pandoc effects.
-- NB: Resulting documents are *Lazy* Text, as produced by the Blaze render function.
knitHtmls
  :: (MonadIO m, Ord k, Show k)
  => KnitConfig c k ct
  -> P.Sem (KnitEffectDocsStack c k ct m) ()
  -> m (Either PA.PandocError [KP.DocWithInfo KP.PandocInfo TL.Text])
knitHtmls config =
  let KO.PandocWriterConfig mFP tv oF = pandocWriterConfig config
  in  consumeKnitEffectStack config . KD.toDocListWithM
        (\(KP.PandocInfo _ tv') a ->
          fmap BH.renderHtml
            . KO.toBlazeDocument (KO.PandocWriterConfig mFP (tv' <> tv) oF)
            $ a
        )
{-# INLINEABLE knitHtmls #-}

-- | Create HTML Text from pandoc fragments.
-- In use, you may need a type-application to specify @m@.
-- This allows use of any underlying monad to handle the Pandoc effects.
-- NB: Resulting document is *Lazy* Text, as produced by the Blaze render function.
knitHtml
  :: (MonadIO m, Ord k, Show k)
  => KnitConfig c k ct
  -> P.Sem (KnitEffectDocStack c k ct m) ()
  -> m (Either PA.PandocError TL.Text)
knitHtml config =
  fmap (fmap (fmap BH.renderHtml)) (consumeKnitEffectStack config)
    . KO.pandocWriterToBlazeDocument (pandocWriterConfig config)
{-# INLINEABLE knitHtml #-}                               

-- | Constraints required to knit a document using effects from a base monad m.
type KnitBase m effs = (MonadIO m, P.Member (P.Embed m) effs)

-- | lift an action in a base monad into a Polysemy monad.  This is just a renaming of `P.embed` for convenience.
liftKnit :: P.Member (P.Embed m) r => m a -> P.Sem r a
liftKnit = P.embed
{-# INLINE liftKnit #-}                               

--type KnitCache =  KC.AtomicCache T.Text (Streamly.Array.Array Word.Word8)

-- | Constraint alias for the effects we need (and run)
-- when calling 'knitHtml' or 'knitHtmls'.
-- Anything inside a call to Knit can use any of these effects.
-- Any other effects added to this stack will need to be run before @knitHtml(s)@
type KnitEffects c k ct r = (KPM.PandocEffects r
                            , P.Members [ KUI.UnusedId
                                        , KE.KnitEnv c ct
                                        , KLog.Logger KLog.LogEntry
                                        , KLog.PrefixLog
                                        , P.Async
                                        , KC.Cache k ct
                                        , PE.Error KC.CacheError
                                        , PE.Error Exceptions.SomeException
                                        , PE.Error PA.PandocError
                                        , P.Embed IO] r
                            )

-- | Constraint alias for the effects we need to knit one document
type KnitOne c k ct r = (KnitEffects c k ct r, P.Member KP.ToPandoc r)

-- | Constraint alias for the effects we need to knit multiple documents.
type KnitMany c k ct r = (KnitEffects c k ct r, P.Member KP.Pandocs r)

-- | Constraint for standard effects stack with all cache parameters set to defaults
type DefaultEffects r = KnitEffects S.Serialize T.Text KS.DefaultCacheData r

-- | Constraint for effects to knit one document with all cache parameters set to defaults
type DefaultKnitOne r = KnitOne S.Serialize T.Text KS.DefaultCacheData r

-- | Constraint for effects to knit many documents with all cache parameters set to defaults
type DefaultKnitMany r = KnitMany S.Serialize T.Text KS.DefaultCacheData r


-- From here down is unexported.  
-- | The exact stack we are interpreting when we knit
#if MIN_VERSION_pandoc(2,8,0)
type KnitEffectStack c k ct m
  = '[ KE.KnitEnv c ct
     , KUI.UnusedId
     , KPM.Template
     , KPM.Pandoc
     , KC.Cache k ct
     , KLog.Logger KLog.LogEntry
     , KLog.PrefixLog
     , P.Async
     , PE.Error IOError
     , PE.Error KC.CacheError
     , PE.Error Exceptions.SomeException
     , PE.Error PA.PandocError
     , P.Embed IO
     , P.Embed m
     , P.Final m]
#else
type KnitEffectStack c k ct m
  = '[ KE.KnitEnv c ct --PR.Reader KLog.LogWithPrefixIO -- so we can asynchronously log without the sem stack
     , KUI.UnusedId
     , KPM.Pandoc
     , KC.Cache k ct
     , KLog.Logger KLog.LogEntry
     , KLog.PrefixLog
     , P.Async
     , PE.Error IOError
     , PE.Error KC.CacheError
     , PE.Error Exceptions.SomeException
     , PE.Error PA.PandocError
     , P.Embed IO
     , P.Embed m
     , P.Final m]
#endif

-- | Add a Multi-doc writer to the front of the effect list
type KnitEffectDocsStack c k ct m = (KP.Pandocs ': KnitEffectStack c k ct m)

-- | Add a single-doc writer to the front of the effect list
type KnitEffectDocStack c k ct m = (KP.ToPandoc ': KnitEffectStack c k ct m)

-- | run all knit-effects in @KnitEffectStack m@
#if MIN_VERSION_pandoc(2,8,0)
consumeKnitEffectStack
  :: forall c k ct m a
   . (MonadIO m, Ord k, Show k)
  => KnitConfig c k ct
  -> P.Sem (KnitEffectStack c k ct m) a
  -> m (Either PA.PandocError a)
consumeKnitEffectStack config =
  P.runFinal
  . P.embedToFinal
  . PI.embedToMonadIO @m -- interpret (Embed IO) using m
  . PE.runError @KPM.PandocError
  . PE.mapError someExceptionToPandocError
  . PE.mapError cacheErrorToPandocError
  . PE.mapError ioErrorToPandocError -- (\e -> PA.PandocSomeError ("Exceptions.Exception thrown: " <> (T.pack $ show e)))
  . P.asyncToIO -- this has to run after (above) the log, partly so that the prefix state is thread-local.
  . KLog.filteredLogEntriesToIO (logIf config)
  . KC.runPersistenceBackedAtomicInMemoryCache' (persistCache config)
  . KPM.interpretInIO -- PA.PandocIO
  . KPM.interpretTemplateIO    
  . KUI.runUnusedId
  . KE.runKnitEnv (KE.KnitEnvironment KLog.logWithPrefixToIO (serializeDict config))
  . maybe id KLog.wrapPrefix (outerLogPrefix config)
#else
consumeKnitEffectStack
  :: forall c k ct r m a
   . MonadIO m
  => KnitConfig c k ct
  -> P.Sem (KnitEffectStack c k ct m) a
  -> m (Either PA.PandocError a)
consumeKnitEffectStack config =
  P.runFinal
  . P.embedToFinal
  . PI.embedToMonadIO @m -- interpret (Embed IO) using m
  . PE.runError
  . PE.mapError someExceptionToPandocError
  . PE.mapError cacheErrorToPandocError
  . PE.mapError ioErrorToPandocError -- (\e -> PA.PandocSomeError ("Exceptions.Exception thrown: " <> (T.pack $ show e)))
  . P.asyncToIO -- this has to run after (above) the log, partly so that the prefix state is thread-local.
  . KLog.filteredLogEntriesToIO (logIf config)
  . KC.runPersistentBackedAtomicInmemoryCache' (persistCache config)
  . KPM.interpretInIO -- PA.PandocIO        
  . KUI.runUnusedId
  . KE.runKnitEnv (KE.KnitEnvironment KLog.logWithPrefixToIO (serializeDict config))
  . maybe id KLog.wrapPrefix (outerLogPrefix config)
#endif
{-# INLINEABLE consumeKnitEffectStack #-}


ioErrorToPandocError :: IE.IOError -> KPM.PandocError
ioErrorToPandocError e = PA.PandocIOError (KPM.textToPandocText $ ("IOError: " <> (T.pack $ show e))) e
{-# INLINEABLE ioErrorToPandocError #-}

cacheErrorToPandocError :: KC.CacheError -> KPM.PandocError
cacheErrorToPandocError e = PA.PandocSomeError (KPM.textToPandocText $ ("CacheError: " <> (T.pack $ show e)))
{-# INLINEABLE cacheErrorToPandocError #-}

someExceptionToPandocError :: Exceptions.SomeException -> KPM.PandocError
someExceptionToPandocError = PA.PandocSomeError . T.pack . Exceptions.displayException 
{-# INLINEABLE someExceptionToPandocError #-}
