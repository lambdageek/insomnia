module Insomnia.Typecheck.ExtendModelCtx (
  extendTypeSigDeclCtx
  , extendModelCtx
  ) where

import Control.Lens
import Control.Monad.Reader.Class (MonadReader(..))

import Insomnia.Types (Con(..), TypeConstructor(..))
import Insomnia.ModelType (TypeSigDecl(..))

import Insomnia.Typecheck.Env
import Insomnia.Typecheck.SelfSig (SelfSig(..))
import Insomnia.Typecheck.TypeDefn (extendTypeDefnCtx, extendTypeAliasCtx)

extendTypeSigDeclCtx :: TypeConstructor -> TypeSigDecl -> TC a -> TC a
extendTypeSigDeclCtx dcon tsd = do
  case tsd of
    ManifestTypeSigDecl defn -> extendTypeDefnCtx dcon defn
    AbstractTypeSigDecl k ->
      extendDConCtx dcon (GenerativeTyCon $ AbstractType k)
    AliasTypeSigDecl alias -> extendTypeAliasCtx dcon alias
  
-- | Given a (selfified) signature, add all of its fields to the context
-- by prefixing them with the given path - presumably the path of this
-- very module.
extendModelCtx :: SelfSig -> TC a -> TC a
extendModelCtx UnitSelfSig = id
extendModelCtx (ValueSelfSig qvar ty msig) =
  -- TODO: if we are modeling joint distributions, does it ever make
  -- sense to talk about value components of other models?
  local (envGlobals . at qvar ?~ ty)
  . extendModelCtx msig
extendModelCtx (TypeSelfSig (Con p) tsd msig) =
  extendTypeSigDeclCtx (TCGlobal p) tsd
  . extendModelCtx msig
extendModelCtx (SubmodelSelfSig _path subModSig msig) =
  extendModelCtx subModSig
  . extendModelCtx msig