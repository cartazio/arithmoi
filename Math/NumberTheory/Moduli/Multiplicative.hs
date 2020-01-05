-- |
-- Module:      Math.NumberTheory.Moduli.Multiplicative
-- Copyright:   (c) 2017 Andrew Lelechenko
-- Licence:     MIT
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>
--
-- Multiplicative groups of integers modulo m.
--

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module Math.NumberTheory.Moduli.Multiplicative
  ( -- * Multiplicative group
    MultMod
  , multElement
  , isMultElement
  , invertGroup
  -- * Primitive roots
  , PrimitiveRoot
  , unPrimitiveRoot
  , isPrimitiveRoot
  , isPrimitiveRoot'
  , discreteLogarithm
  ) where

-- TODO: (BM) put discreteLogarithmPP into an Internal module so it could be used elsewhere
import Control.Monad
import Data.Constraint
import qualified Data.Map as M
import Data.Maybe
import Data.Mod
import Data.Proxy
import Data.Semigroup
import GHC.Integer.GMP.Internals
import GHC.TypeNats.Compat
import Numeric.Natural

import Math.NumberTheory.ArithmeticFunctions
import Math.NumberTheory.Moduli.Chinese
import Math.NumberTheory.Moduli.Equations
import Math.NumberTheory.Moduli.Singleton
import Math.NumberTheory.Primes
import Math.NumberTheory.Powers.Modular
import Math.NumberTheory.Roots

-- | This type represents elements of the multiplicative group mod m, i.e.
-- those elements which are coprime to m. Use @toMultElement@ to construct.
newtype MultMod m = MultMod {
  multElement :: Mod m -- ^ Unwrap a residue.
  } deriving (Eq, Ord, Show)

instance KnownNat m => Semigroup (MultMod m) where
  MultMod a <> MultMod b = MultMod (a * b)
  stimes k a@(MultMod a')
    | k >= 0 = MultMod (a' ^% k)
    | otherwise = invertGroup $ stimes (-k) a
  -- ^ This Semigroup is in fact a group, so @stimes@ can be called with a negative first argument.

instance KnownNat m => Monoid (MultMod m) where
  mempty = MultMod 1
  mappend = (<>)

instance KnownNat m => Bounded (MultMod m) where
  minBound = MultMod 1
  maxBound = MultMod (-1)

-- | Attempt to construct a multiplicative group element.
isMultElement :: KnownNat m => Mod m -> Maybe (MultMod m)
isMultElement a = if unMod a `gcd` natVal a == 1
                     then Just $ MultMod a
                     else Nothing

-- | For elements of the multiplicative group, we can safely perform the inverse
-- without needing to worry about failure.
invertGroup :: KnownNat m => MultMod m -> MultMod m
invertGroup (MultMod a) = case invertMod a of
                            Just b -> MultMod b
                            Nothing -> error "Math.NumberTheory.Moduli.invertGroup: failed to invert element"

-- | 'PrimitiveRoot' m is a type which is only inhabited
-- by <https://en.wikipedia.org/wiki/Primitive_root_modulo_n primitive roots> of m.
newtype PrimitiveRoot m = PrimitiveRoot
  { unPrimitiveRoot :: MultMod m -- ^ Extract primitive root value.
  }
  deriving (Eq, Show)

-- https://en.wikipedia.org/wiki/Primitive_root_modulo_n#Finding_primitive_roots
isPrimitiveRoot'
  :: (Integral a, UniqueFactorisation a)
  => CyclicGroup a m
  -> a
  -> Bool
isPrimitiveRoot' cg r =
  case cg of
    CG2                       -> r == 1
    CG4                       -> r == 3
    CGOddPrimePower p k       -> oddPrimePowerTest (unPrime p) k r
    CGDoubleOddPrimePower p k -> doubleOddPrimePowerTest (unPrime p) k r
  where
    oddPrimeTest p g              = let phi  = totient p
                                        pows = map (\pk -> phi `quot` unPrime (fst pk)) (factorise phi)
                                        exps = map (\x -> powMod g x p) pows
                                     in g /= 0 && gcd g p == 1 && all (/= 1) exps
    oddPrimePowerTest p 1 g       = oddPrimeTest p (g `mod` p)
    oddPrimePowerTest p _ g       = oddPrimeTest p (g `mod` p) && powMod g (p-1) (p*p) /= 1
    doubleOddPrimePowerTest p k g = odd g && oddPrimePowerTest p k g

-- | Check whether a given modular residue is
-- a <https://en.wikipedia.org/wiki/Primitive_root_modulo_n primitive root>.
--
-- >>> :set -XDataKinds
-- >>> import Data.Maybe
-- >>> isPrimitiveRoot (fromJust cyclicGroup) (1 :: Mod 13)
-- Nothing
-- >>> isPrimitiveRoot (fromJust cyclicGroup) (2 :: Mod 13)
-- Just (PrimitiveRoot {unPrimitiveRoot = MultMod {multElement = (2 `modulo` 13)}})
isPrimitiveRoot
  :: (Integral a, UniqueFactorisation a)
  => CyclicGroup a m
  -> Mod m
  -> Maybe (PrimitiveRoot m)
isPrimitiveRoot cg r = case proofFromCyclicGroup cg of
  Sub Dict -> do
    r' <- isMultElement r
    guard $ isPrimitiveRoot' cg (fromIntegral (unMod r))
    return $ PrimitiveRoot r'

-- | Computes the discrete logarithm. Currently uses a combination of the baby-step
-- giant-step method and Pollard's rho algorithm, with Bach reduction.
--
-- >>> :set -XDataKinds
-- >>> import Data.Maybe
-- >>> let cg = fromJust cyclicGroup :: CyclicGroup Integer 13
-- >>> let rt = fromJust (isPrimitiveRoot cg 2)
-- >>> let x  = fromJust (isMultElement 11)
-- >>> discreteLogarithm cg rt x
-- 7
discreteLogarithm :: CyclicGroup Integer m -> PrimitiveRoot m -> MultMod m -> Natural
discreteLogarithm cg (multElement . unPrimitiveRoot -> a) (multElement -> b) = case cg of
  CG2
    -> 0
    -- the only valid input was a=1, b=1
  CG4
    -> if unMod b == 1 then 0 else 1
    -- the only possible input here is a=3 with b = 1 or 3
  CGOddPrimePower (unPrime -> p) k
    -> discreteLogarithmPP p k (toInteger (unMod a)) (toInteger (unMod b))
  CGDoubleOddPrimePower (unPrime -> p) k
    -> discreteLogarithmPP p k (toInteger (unMod a) `rem` p^k) (toInteger (unMod b) `rem` p^k)
    -- we have the isomorphism t -> t `rem` p^k from (Z/2p^kZ)* -> (Z/p^kZ)*

-- Implementation of Bach reduction (https://www2.eecs.berkeley.edu/Pubs/TechRpts/1984/CSD-84-186.pdf)
{-# INLINE discreteLogarithmPP #-}
discreteLogarithmPP :: Integer -> Word -> Integer -> Integer -> Natural
discreteLogarithmPP p 1 a b = discreteLogarithmPrime p a b
discreteLogarithmPP p k a b = fromInteger $ if result < 0 then result + pkMinusPk1 else result
  where
    baseSol    = toInteger $ discreteLogarithmPrime p (a `rem` p) (b `rem` p)
    thetaA     = theta p pkMinusOne a
    thetaB     = theta p pkMinusOne b
    pkMinusOne = p^(k-1)
    pkMinusPk1 = pkMinusOne * (p - 1)
    c          = (recipModInteger thetaA pkMinusOne * thetaB) `rem` pkMinusOne
    result     = fromJust $ chineseCoprime (baseSol, p-1) (c, pkMinusOne)

-- compute the homomorphism theta given in https://math.stackexchange.com/a/1864495/418148
{-# INLINE theta #-}
theta :: Integer -> Integer -> Integer -> Integer
theta p pkMinusOne a = (numerator `quot` pk) `rem` pkMinusOne
  where
    pk           = pkMinusOne * p
    p2kMinusOne  = pkMinusOne * pk
    numerator    = (powModInteger a (pk - pkMinusOne) p2kMinusOne - 1) `rem` p2kMinusOne

-- TODO: Use Pollig-Hellman to reduce the problem further into groups of prime order.
-- While Bach reduction simplifies the problem into groups of the form (Z/pZ)*, these
-- have non-prime order, and the Pollig-Hellman algorithm can reduce the problem into
-- smaller groups of prime order.
-- In addition, the gcd check before solveLinear is applied in Pollard below will be
-- made redundant, since n would be prime.
discreteLogarithmPrime :: Integer -> Integer -> Integer -> Natural
discreteLogarithmPrime p a b
  | p < 100000000 = fromIntegral $ discreteLogarithmPrimeBSGS (fromInteger p) (fromInteger a) (fromInteger b)
  | otherwise     = discreteLogarithmPrimePollard p a b

discreteLogarithmPrimeBSGS :: Int -> Int -> Int -> Int
discreteLogarithmPrimeBSGS p a b = head [i*m + j | (v,i) <- zip giants [0..m-1], j <- maybeToList (M.lookup v table)]
  where
    m        = integerSquareRoot (p - 2) + 1 -- simple way of ceiling (sqrt (p-1))
    babies   = iterate (.* a) 1
    table    = M.fromList (zip babies [0..m-1])
    aInv     = recipModInteger (toInteger a) (toInteger p)
    bigGiant = fromInteger $ powModInteger aInv (toInteger m) (toInteger p)
    giants   = iterate (.* bigGiant) b
    x .* y   = x * y `rem` p

-- TODO: Use more advanced walks, in order to reduce divisions, cf
-- https://maths-people.anu.edu.au/~brent/pd/rpb231.pdf
-- This will slightly improve the expected time to collision, and can reduce the
-- number of divisions performed.
discreteLogarithmPrimePollard :: Integer -> Integer -> Integer -> Natural
discreteLogarithmPrimePollard p a b =
  case concatMap runPollard [(x,y) | x <- [0..n], y <- [0..n]] of
    (t:_)  -> fromInteger t
    []     -> error ("discreteLogarithm: pollard's rho failed, please report this as a bug. inputs " ++ show [p,a,b])
  where
    n                 = p-1 -- order of the cyclic group
    halfN             = n `quot` 2
    mul2 m            = if m < halfN then m * 2 else m * 2 - n
    sqrtN             = integerSquareRoot n
    step (xi,!ai,!bi) = case xi `rem` 3 of
                          0 -> (xi*xi `rem` p, mul2 ai, mul2 bi)
                          1 -> ( a*xi `rem` p,    ai+1,      bi)
                          _ -> ( b*xi `rem` p,      ai,    bi+1)
    initialise (x,y)  = (powModInteger a x n * powModInteger b y n `rem` n, x, y)
    begin t           = go (step t) (step (step t))
    check t           = powModInteger a t p == b
    go tort@(xi,ai,bi) hare@(x2i,a2i,b2i)
      | xi == x2i, gcd (bi - b2i) n < sqrtN = case someNatVal (fromInteger n) of
        SomeNat (Proxy :: Proxy n) -> map (toInteger . unMod) $ solveLinear (fromInteger (bi - b2i) :: Mod n) (fromInteger (ai - a2i))
      | xi == x2i                           = []
      | otherwise                           = go (step tort) (step (step hare))
    runPollard        = filter check . begin . initialise
