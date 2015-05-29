{-# LANGUAGE OverloadedStrings #-}
module Insomnia.Main.Stage (Stage(..)
                           , (->->-)
                           , conditionalStage
                           , startingFrom
                           , compilerDone) where

import Control.Monad.Reader
import Data.Monoid

import qualified Data.Format as F

import Insomnia.Main.Config
import Insomnia.Main.Monad

data Stage a b = Stage { bannerStage :: F.Doc 
                       , performStage :: a -> InsomniaMain b
                       , formatStage :: b -> F.Doc }

(->->-) :: Stage a b -> Stage b c -> Stage a c
stage1 ->->- stage2 = Stage {
  bannerStage = bannerStage stage1
  , performStage = \x -> do
    y <- performStage stage1 x
    putDebugDoc (formatStage stage1 y <> F.newline)
    putDebugStrLn "--------------------✂✄--------------------"
    putDebugDoc (bannerStage stage2 <> F.newline)
    performStage stage2 y
  , formatStage = formatStage stage2
  }

infixr 6 ->->-

compilerDone :: Stage a ()
compilerDone = Stage { bannerStage = mempty
                     , performStage = const (return ())
                     , formatStage = mempty
                     }

conditionalStage :: InsomniaMain Bool -> Stage a a -> Stage a a
conditionalStage shouldRun stage =
  Stage { bannerStage = bannerStage stage
        , performStage = \inp -> do
          b <- shouldRun
          case b of
           True -> performStage stage inp
           False -> do
             putErrorDoc ("SKIPPED " <> bannerStage stage)
             return inp
        , formatStage = formatStage stage
        }


startingFrom :: a -> Stage a () -> InsomniaMain ()
startingFrom a stages = do
  putDebugDoc (bannerStage stages <> F.newline)
  performStage stages a

