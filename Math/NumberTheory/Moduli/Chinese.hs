-- |
-- Module:      Math.NumberTheory.Moduli.Chinese
-- Copyright:   (c) 2011 Daniel Fischer, 2018 Andrew Lelechenko
-- Licence:     MIT
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>
--
-- Chinese remainder theorem
--

{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Math.NumberTheory.Moduli.Chinese
  ( -- * Safe interface
    chinese
  , chineseSomeMod
  ) where

import Prelude hiding ((^), (+), (-), (*), rem, mod, quot, gcd, lcm)

import Data.Euclidean
import Data.Mod
import Data.Ratio
import Data.Semiring (Semiring(..), (+), (-), (*), Ring)
import GHC.TypeNats (KnownNat, natVal)

import Math.NumberTheory.Moduli.SomeMod

-- | 'chinese' @(n1, m1)@ @(n2, m2)@ returns @(n, lcm m1 m2)@ such that
-- @n \`mod\` m1 == n1@ and @n \`mod\` m2 == n2@, if exists.
-- Moduli @m1@ and @m2@ are allowed to have common factors.
--
-- >>> chinese (1, 2) (2, 3)
-- Just (-1, 6)
-- >>> chinese (3, 4) (5, 6)
-- Just (-1, 12)
-- >>> chinese (3, 4) (2, 6)
-- Nothing
chinese :: forall a. (Eq a, Ring a, Euclidean a) => (a, a) -> (a, a) -> Maybe (a, a)
chinese (n1, m1) (n2, m2)
  | d == one
  = Just ((v * m2 * n1 + u * m1 * n2) `rem` m, m)
  | (n1 - n2) `rem` d == zero
  = Just ((v * (m2 `quot` d) * n1 + u * (m1 `quot` d) * n2) `rem` m, m)
  | otherwise
  = Nothing
  where
    (d, u, v) = extendedGCD m1 m2
    m = if d == one then m1 * m2 else (m1 `quot` d) * m2

{-# SPECIALISE chinese :: (Int, Int) -> (Int, Int) -> Maybe (Int, Int) #-}
{-# SPECIALISE chinese :: (Word, Word) -> (Word, Word) -> Maybe (Word, Word) #-}
{-# SPECIALISE chinese :: (Integer, Integer) -> (Integer, Integer) -> Maybe (Integer, Integer) #-}

isCompatible :: KnownNat m => Mod m -> Rational -> Bool
isCompatible n r = case invertMod (fromInteger (denominator r)) of
  Nothing -> False
  Just r' -> r' * fromInteger (numerator r) == n

-- | Same as 'chinese', but operates on residues.
--
-- >>> :set -XDataKinds
-- >>> import Data.Mod
-- >>> (1 `modulo` 2) `chineseSomeMod` (2 `modulo` 3)
-- Just (5 `modulo` 6)
-- >>> (3 `modulo` 4) `chineseSomeMod` (5 `modulo` 6)
-- Just (11 `modulo` 12)
-- >>> (3 `modulo` 4) `chineseSomeMod` (2 `modulo` 6)
-- Nothing
chineseSomeMod :: SomeMod -> SomeMod -> Maybe SomeMod
chineseSomeMod (SomeMod n1) (SomeMod n2)
  = (\(n, m) -> n `modulo` fromInteger m) <$> chinese
    (toInteger $ unMod n1, toInteger $ natVal n1)
    (toInteger $ unMod n2, toInteger $ natVal n2)
chineseSomeMod (SomeMod n) (InfMod r)
  | isCompatible n r = Just $ InfMod r
  | otherwise        = Nothing
chineseSomeMod (InfMod r) (SomeMod n)
  | isCompatible n r = Just $ InfMod r
  | otherwise        = Nothing
chineseSomeMod (InfMod r1) (InfMod r2)
  | r1 == r2  = Just $ InfMod r1
  | otherwise = Nothing

-------------------------------------------------------------------------------
-- Utils

extendedGCD :: (Eq a, Ring a, Euclidean a) => a -> a -> (a, a, a)
extendedGCD a b = (g, s, t)
  where
    (g, s) = gcdExt a b
    t = (g - a * s) `quot` b
