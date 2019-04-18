{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE GADTs                #-}
{-|
Module      : Knit.Report.Output.Html
Description : Output Pandoc as Html
Copyright   : (c) Adam Conner-Sax 2019
License     : BSD-3-Clause
Maintainer  : adam_conner_sax@yahoo.com
Stability   : experimental

Functions to produce Html output for a Pandoc report.
-}
module Knit.Report.Output.Html
  (
    -- * Default Options
    htmlWriterOptions

    -- * Formatted output
  , toBlazeDocument
  , pandocWriterToBlazeDocument

  -- * Options helper  
  , mindocOptionsF

  -- * Other helpers
  , markDownTextToBlazeFragment
  )
where


import qualified Data.ByteString.Char8         as BS
import qualified Data.Text                     as T
import qualified Data.Map                      as M
import qualified Text.Blaze.Html               as BH
import qualified Text.Pandoc                   as PA

import qualified Polysemy                      as P
import qualified Knit.Effect.Pandoc           as PE
import qualified Knit.Effect.PandocMonad      as PM

import           Knit.Report.Input.MarkDown.PandocMarkDown (markDownReaderOptions)

-- | Base Html writer options, with support for MathJax
htmlWriterOptions :: PA.WriterOptions
htmlWriterOptions = PA.def
  { PA.writerExtensions     = PA.extensionsFromList [PA.Ext_raw_html]
  , PA.writerHTMLMathMethod = PA.MathJax ""
  }

-- | Full writer options which use pandoc monad for template access
htmlFullDocWriterOptions
  :: PA.PandocMonad m
  => Maybe FilePath -- ^ path to template to include, @Nothing@ for no template.
  -> M.Map String String -- ^ template Variable substitutions
  -> m PA.WriterOptions 
htmlFullDocWriterOptions pathM templateVars = do
  template <- case pathM of
    Nothing -> PA.getDefaultTemplate "Html5"
    Just fp -> do
      exists <- PA.fileExists fp
      if exists
        then fmap BS.unpack (PA.readFileStrict fp)
        else PA.logOutput (PA.IgnoredIOError ("Couldn't find " ++ show fp))
          >> PA.getDefaultTemplate "Html5"
  return $ htmlWriterOptions { PA.writerTemplate      = Just template
                             , PA.writerVariables     = M.toList templateVars
                             , PA.writerSetextHeaders = True
                             }


-- | Convert markDown to Blaze
markDownTextToBlazeFragment
  :: PM.PandocEffects effs
  => T.Text -- ^ markDown Text
  -> P.Semantic effs BH.Html
markDownTextToBlazeFragment =
  PE.fromPandocE PE.WriteHtml5 htmlWriterOptions
    . PE.addFrom PE.ReadMarkDown markDownReaderOptions

-- | Convert given Pandoc to Blaze Html.
-- Incudes support for template and template variables and changes to the default writer options
toBlazeDocument
  :: PM.PandocEffects effs
  => Maybe FilePath -- ^ path to Pandoc template or @Nothing@ for no template
  -> M.Map String String -- ^ template variable substitutions
  -> (PA.WriterOptions -> PA.WriterOptions) -- ^ modify the Pandoc Writer Options
  -> PE.PandocWithRequirements -- ^ Union of input requirements 
  -> P.Semantic effs BH.Html
toBlazeDocument templatePathM templateVars optionsF pdocWR = do
  writerOptions <- htmlFullDocWriterOptions templatePathM templateVars
  PE.fromPandoc PE.WriteHtml5 (optionsF writerOptions) pdocWR

-- | Convert current Pandoc document (from the ToPandoc effect) into a Blaze Html document.
-- Incudes support for template and template variables and changes to the default writer options. 
pandocWriterToBlazeDocument
  :: PM.PandocEffects effs
  => Maybe FilePath -- ^ path to Pandoc template or @Nothing@ for no template
  -> M.Map String String -- ^ template variable substitutions
  -> (PA.WriterOptions -> PA.WriterOptions) -- ^ modify the Pandoc Writer Options
  -> P.Semantic (PE.ToPandoc ': effs) () -- ^ effects stack to run to get Pandoc
  -> P.Semantic effs BH.Html
pandocWriterToBlazeDocument templatePathM templateVars optionsF pw =
  PE.runPandocWriter pw >>= toBlazeDocument templatePathM templateVars optionsF

-- | options for the mindoc template
mindocOptionsF :: PA.WriterOptions -> PA.WriterOptions
mindocOptionsF op = op { PA.writerSectionDivs = True }
