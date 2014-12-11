{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFoldable     #-}
{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DeriveTraversable  #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TypeFamilies       #-}
-- | Manipulate @GenericPackageDescription@ from Cabal into something more
-- useful for us.
module Stackage2.PackageDescription
    ( SimpleDesc (..)
    , toSimpleDesc
    , CheckCond (..)
    , Component (..)
    , DepInfo (..)
    ) where

import           Control.Monad.Writer.Strict     (MonadWriter, execWriterT,
                                                  tell)
import           Data.Aeson
import qualified Data.Map                        as Map
import           Distribution.Compiler           (CompilerFlavor)
import           Distribution.Package            (Dependency (..))
import           Distribution.PackageDescription
import           Distribution.System             (Arch, OS)
import           Stackage2.Prelude

data Component = CompLibrary
               | CompExecutable
               | CompTestSuite
               | CompBenchmark
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

compToText :: Component -> Text
compToText CompLibrary = "library"
compToText CompExecutable = "executable"
compToText CompTestSuite = "test-suite"
compToText CompBenchmark = "benchmark"

instance ToJSON Component where
    toJSON = toJSON . compToText
instance FromJSON Component where
    parseJSON = withText "Component" $ \t -> maybe
        (fail $ "Invalid component: " ++ unpack t)
        return
        (lookup t comps)
      where
        comps = asHashMap $ mapFromList $ map (compToText &&& id) [minBound..maxBound]

data DepInfo = DepInfo
    { diComponents :: Set Component
    , diRange :: VersionRange
    }
    deriving (Show, Eq)

instance Semigroup DepInfo where
    DepInfo a x <> DepInfo b y = DepInfo
        (a <> b)
        (intersectVersionRanges x y)
instance ToJSON DepInfo where
    toJSON DepInfo {..} = object
        [ "components" .= diComponents
        , "range" .= display diRange
        ]
instance FromJSON DepInfo where
    parseJSON = withObject "DepInfo" $ \o -> do
        diComponents <- o .: "components"
        diRange <- o .: "range" >>= either (fail . show) return . simpleParse
        return DepInfo {..}

-- | A simplified package description that tracks:
--
-- * Package dependencies
--
-- * Build tool dependencies
--
-- * Provided executables
--
-- It has fully resolved all conditionals
data SimpleDesc = SimpleDesc
    { sdPackages     :: Map PackageName DepInfo
    , sdTools        :: Map ExeName DepInfo
    , sdProvidedExes :: Set ExeName
    }
    deriving (Show, Eq)
instance Monoid SimpleDesc where
    mempty = SimpleDesc mempty mempty mempty
    mappend (SimpleDesc a b c) (SimpleDesc x y z) = SimpleDesc
        (unionWith (<>) a x)
        (unionWith (<>) b y)
        (c ++ z)
instance ToJSON SimpleDesc where
    toJSON SimpleDesc {..} = object
        [ "packages" .= Map.mapKeysWith const unPackageName sdPackages
        , "tools" .= Map.mapKeysWith const unExeName sdTools
        , "provided-exes" .= sdProvidedExes
        ]
instance FromJSON SimpleDesc where
    parseJSON = withObject "SimpleDesc" $ \o -> do
        sdPackages <- Map.mapKeysWith const mkPackageName <$> (o .: "packages")
        sdTools <- Map.mapKeysWith const ExeName <$> (o .: "tools")
        sdProvidedExes <- o .: "provided-exes"
        return SimpleDesc {..}

-- | Convert a 'GenericPackageDescription' into a 'SimpleDesc' by following the
-- constraints in the provided 'CheckCond'.
toSimpleDesc :: MonadThrow m
             => CheckCond
             -> GenericPackageDescription
             -> m SimpleDesc
toSimpleDesc cc gpd = execWriterT $ do
    forM_ (condLibrary gpd) $ tellTree cc CompLibrary libBuildInfo
    forM_ (condExecutables gpd) $ tellTree cc CompExecutable buildInfo . snd
    tell mempty { sdProvidedExes = setFromList
                                 $ map (fromString . fst)
                                 $ condExecutables gpd
                }
    when (ccIncludeTests cc) $ forM_ (condTestSuites gpd)
        $ tellTree cc CompTestSuite testBuildInfo . snd
    when (ccIncludeBenchmarks cc) $ forM_ (condBenchmarks gpd)
        $ tellTree cc CompBenchmark benchmarkBuildInfo . snd

-- | Convert a single CondTree to a 'SimpleDesc'.
tellTree :: (MonadWriter SimpleDesc m, MonadThrow m)
         => CheckCond
         -> Component
         -> (a -> BuildInfo)
         -> CondTree ConfVar [Dependency] a
         -> m ()
tellTree cc component getBI (CondNode dat deps comps) = do
    tell mempty
        { sdPackages = unionsWith (<>) $ flip map deps
            $ \(Dependency x y) -> singletonMap x DepInfo
                { diComponents = singletonSet component
                , diRange = simplifyVersionRange y
                }
        , sdTools = unionsWith (<>) $ flip map (buildTools $ getBI dat)
            $ \(Dependency name range) -> singletonMap
                -- In practice, cabal files refer to the exe name, not the
                -- package name.
                (ExeName $ unPackageName name)
                DepInfo
                    { diComponents = singletonSet component
                    , diRange = simplifyVersionRange range
                    }
        }
    forM_ comps $ \(cond, ontrue, onfalse) -> do
        b <- checkCond cc cond
        if b
            then tellTree cc component getBI ontrue
            else maybe (return ()) (tellTree cc component getBI) onfalse

-- | Resolve a condition to a boolean based on the provided 'CheckCond'.
checkCond :: MonadThrow m => CheckCond -> Condition ConfVar -> m Bool
checkCond CheckCond {..} cond0 =
    go cond0
  where
    go (Var (OS os)) = return $ os == ccOS
    go (Var (Arch arch)) = return $ arch == ccArch
    go (Var (Flag flag)) =
        case lookup flag ccFlags of
            Nothing -> throwM $ FlagNotDefined ccPackageName flag cond0
            Just b -> return b
    go (Var (Impl flavor range)) = return
                                 $ flavor == ccCompilerFlavor
                                && ccCompilerVersion `withinRange` range
    go (Lit b) = return b
    go (CNot c) = not `liftM` go c
    go (CAnd x y) = (&&) `liftM` go x `ap` go y
    go (COr x y) = (||) `liftM` go x `ap` go y

data CheckCondException = FlagNotDefined PackageName FlagName (Condition ConfVar)
    deriving (Show, Typeable)
instance Exception CheckCondException

data CheckCond = CheckCond
    { ccPackageName       :: PackageName -- for debugging only
    , ccOS                :: OS
    , ccArch              :: Arch
    , ccFlags             :: Map FlagName Bool
    , ccCompilerFlavor    :: CompilerFlavor
    , ccCompilerVersion   :: Version
    , ccIncludeTests      :: Bool
    , ccIncludeBenchmarks :: Bool
    }