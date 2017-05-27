module Data.Units.Types where

import Data.List
import Data.Function
import Control.Arrow

data BaseDimension = Mass | Distance | Luminosity | Time | Temperature | Current
    deriving (Show, Eq, Ord)

-- a dimension defined in terms of (t1*t2*t3...*tN)/(b1*b2*b3...*bN)
data Dimension = Dimension [BaseDimension] [BaseDimension] | Dimensionless deriving Show

instance Eq Dimension where
    (==) Dimensionless Dimensionless = True
    (==) (Dimension _ _) Dimensionless = False
    (==) Dimensionless (Dimension _ _) = False
    (==) a b = let
        (Dimension ts bs,Dimension ts' bs') = (reduceDim a, reduceDim b) in
            (sort ts == sort ts') && (sort bs == sort bs')

reduceDim :: Dimension -> Dimension
reduceDim Dimensionless = Dimensionless
reduceDim (Dimension ts bs) = reducer (sort ts) (sort bs) where
    reducer [] ys = Dimension [] ys
    reducer (x:xs) ys = if elem x ys
        then reducer xs (delete x ys)
        else let (Dimension ts bs) = reducer xs ys in Dimension (x:ts) bs

-- basic unit types
type Abbrev = String
type Fullname = String
data BaseUnit = BaseUnit Abbrev Fullname BaseDimension deriving (Show,Eq,Ord)
data DerivedUnit = DerivedUnit Abbrev Fullname
    [(Rational,BaseUnit)] [(Rational,BaseUnit)] deriving Show

class Dimensioned a where
    dimension :: a -> Dimension

instance Dimensioned BaseUnit where
    dimension (BaseUnit _ _ d) = Dimension [d] []

instance Dimensioned DerivedUnit where
    dimension (DerivedUnit _ _ ts bs) =
        reduceDim $ Dimension (tts ++ bbs) (tbs ++ bts) where
            onBoth :: (a -> b) -> (a,a) -> (b,b)
            onBoth f (x,y) = (f x, f y)
            dimensions :: [(Rational,BaseUnit)] -> [Dimension]
            dimensions = filter (\x->not $ x == Dimensionless) . map (dimension . snd)
            (tts,tbs) = onBoth concat $ unzip $ map (\(Dimension t b)->(t,b)) $ dimensions ts
            (bts,bbs) = onBoth concat $ unzip $ map (\(Dimension t b)->(t,b)) $ dimensions bs

isCompat :: (Dimensioned a, Dimensioned b) => a -> b -> Bool
isCompat a b = (dimension a) == (dimension b)

multiplyDims :: Dimension -> Dimension -> Dimension
multiplyDims (Dimension ts bs) (Dimension ts' bs') = reduceDim $
    Dimension (ts++ts') (bs++bs')

-- a consistent system of units
data UnitSystem = UnitSystem {
    baseUnits :: [BaseUnit],
    derivedUnits :: [DerivedUnit] } deriving Show

-- anonymous unit type used when evaluating expressions
newtype AnonymousUnit = AnonymousUnit
    ([(Rational,BaseUnit)],[(Rational,BaseUnit)]) deriving Show
class Unit a where
    toFrac :: a -> AnonymousUnit

instance Unit BaseUnit where
    toFrac x = AnonymousUnit ([(1,x)],[])

instance Unit DerivedUnit where
    toFrac (DerivedUnit _ _ ts bs) = AnonymousUnit (ts,bs)

instance Unit AnonymousUnit where
    toFrac x = x

(>*) :: (Unit a, Unit b) => a -> b -> AnonymousUnit
(>*) a b = AnonymousUnit (aTop ++ bTop, aBot ++ bBot) where
    (AnonymousUnit (aTop,aBot)) = toFrac a
    (AnonymousUnit (bTop,bBot)) = toFrac b

(>/) :: (Unit a, Unit b) => a -> b -> AnonymousUnit
(>/) a b = AnonymousUnit (aTop ++ bBot, aBot ++ bTop) where
    (AnonymousUnit (aTop,aBot)) = toFrac a
    (AnonymousUnit (bTop,bBot)) = toFrac b

inv :: (Unit a) => a -> AnonymousUnit
inv = (\(AnonymousUnit (a,b))->(AnonymousUnit (b,a))) . toFrac

reduceUnit :: Unit a => a -> AnonymousUnit
reduceUnit u = reducer (sortFactors ts) (sortFactors bs) where
    (AnonymousUnit (ts,bs)) = toFrac u
    sortFactors :: [(a,BaseUnit)] -> [(a,BaseUnit)]
    sortFactors = sortBy (compare `on` snd)
    reducer [] ys = AnonymousUnit ([],ys)
    reducer (x:xs) ys = if elem x ys then reducer xs (delete x ys) else
        let (AnonymousUnit (ts,bs)) = reducer xs ys in AnonymousUnit (x:ts,bs)

-- all units are dimensioned
instance Dimensioned AnonymousUnit where
    dimension (AnonymousUnit (t,b)) = Dimension dt db where
        dimify :: (Rational,BaseUnit) -> BaseDimension
        dimify = (\(BaseUnit _ _ x)->x) . snd
        (dt,db) = (map dimify t, map dimify b)