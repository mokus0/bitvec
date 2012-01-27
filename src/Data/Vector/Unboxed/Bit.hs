{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE BangPatterns               #-}
module Data.Vector.Unboxed.Bit
     ( module Data.Bit
     , module U
     
     , wordSize
     , fromWords
     , toWords
     , indexWord
     
     , bitwiseZip
     
     , union
     , unions
     
     , intersection
     , intersections
     , difference
     , symDiff
     
     , invert
     
     , select
     , selectBits
     
     , exclude
     , excludeBits
     
     , countBits
     
     , and
     , or
     
     , any
     , anyBits
     , all
     , allBits
     
     , reverse
     
     , first
     , findIndex
     ) where

import           Control.Monad
import           Control.Monad.ST
import           Data.Bit
import           Data.Bit.Internal
import           Data.Bits
import qualified Data.Vector.Generic                as V
import qualified Data.Vector.Generic.Mutable        as MV
import           Data.Vector.Unboxed                as U
    hiding (and, or, any, all, reverse, findIndex)
import qualified Data.Vector.Unboxed.Mutable.Bit    as B
import           Data.Vector.Unboxed.Bit.Internal
import           Data.Word
import           Prelude                            as P
    hiding (and, or, any, all, reverse)

-- |Given a number of bits and a vector of words, concatenate them to a vector of bits (interpreting the words in little-endian order, as described at 'indexWord').  If there are not enough words for the number of bits requested, the vector will be zero-padded.
fromWords :: Int -> U.Vector Word -> U.Vector Bit
fromWords n ws
    | n < m     = pad n (BitVec 0 m ws)
    | otherwise = BitVec 0 n (V.take (nWords n) ws)
    where 
         m = nBits (V.length ws)

-- |Given a vector of bits, extract an unboxed vector of words.  If the bits don't completely fill the words, the last word will be zero-padded.
toWords :: U.Vector Bit -> U.Vector Word
toWords v@(BitVec s n ws)
    | aligned s && (aligned n || isMasked (modWordSize n) (indexWord v (alignDown n)))
         = V.slice (divWordSize s) (divWordSize n) ws
    | otherwise = runST (V.unsafeThaw v >>= cloneWords >>= V.unsafeFreeze)

-- |For a bitwise operation @op@ (whose 1-bit equivalent is @op'@),
-- @bitwiseZip op xs ys == V.fromList (zipWith op' (V.toList xs) (V.toList ys))@, and the former is computed much more quickly.
{-# INLINE bitwiseZip #-}
bitwiseZip :: (Word -> Word -> Word) -> U.Vector Bit -> U.Vector Bit -> U.Vector Bit
bitwiseZip op xs ys
    | V.length xs < V.length ys =
        bitwiseZip (flip op) ys xs
    | otherwise =  runST $ do
        ys <- V.thaw ys
        let f i y = return (indexWord xs i `op` y)
        B.mapMInPlaceWithIndex f ys
        V.unsafeFreeze ys

-- |(internal) N-ary 'bitwiseZip' with a unit value and specified output length.  The first input is assumed to be a unit of the operation (on both sides).
{-# INLINE zipMany #-}
zipMany :: Word -> (Word -> Word -> Word) -> Int -> [U.Vector Bit] -> U.Vector Bit
zipMany z op n xss = runST $ do
    ys <- MV.new n
    B.mapMInPlace (return . const z) ys
    P.mapM_ (B.zipInPlace op ys) xss
    V.unsafeFreeze ys

union        = bitwiseZip (.|.)
intersection = bitwiseZip (.&.)
difference   = bitwiseZip diff
symDiff      = bitwiseZip xor

unions        = zipMany 0 (.|.)
intersections = zipMany (complement 0) (.&.)

-- |Flip every bit in the given vector
invert :: U.Vector Bit -> U.Vector Bit
invert xs = runST $ do
    ys <- MV.new (V.length xs)
    let f i _ = return (complement (indexWord xs i))
    B.mapMInPlaceWithIndex f ys
    V.unsafeFreeze ys

-- | Given a vector of bits and a vector of things, extract those things for which the corresponding bit is set.
-- 
-- For example, @select (V.map (fromBool . p) x) x == V.filter p x@.
select :: (V.Vector v1 Bit, V.Vector v2 t) => v1 Bit -> v2 t -> v2 t
select is xs = V.unfoldr next 0
    where
        n = min (V.length is) (V.length xs)
        
        next j
            | j >= n             = Nothing
            | toBool (is V.! j)  = Just (xs V.! j, j + 1)
            | otherwise          = next           (j + 1)

-- | Given a vector of bits and a vector of things, extract those things for which the corresponding bit is unset.
-- 
-- For example, @exclude (V.map (fromBool . p) x) x == V.filter (not . p) x@.
exclude :: (V.Vector v1 Bit, V.Vector v2 t) => v1 Bit -> v2 t -> v2 t
exclude is xs = V.unfoldr next 0
    where
        n = min (V.length is) (V.length xs)
        
        next j
            | j >= n             = Nothing
            | toBool (is V.! j)  = next           (j + 1)
            | otherwise          = Just (xs V.! j, j + 1)

selectBits :: U.Vector Bit -> U.Vector Bit -> U.Vector Bit
selectBits is xs = runST $ do
    xs <- U.thaw xs
    n <- B.selectBitsInPlace is xs
    U.unsafeFreeze (MV.take n xs)

excludeBits :: U.Vector Bit -> U.Vector Bit -> U.Vector Bit
excludeBits is xs = runST $ do
    xs <- U.thaw xs
    n <- B.excludeBitsInPlace is xs
    U.unsafeFreeze (MV.take n xs)

-- |return the number of ones in a bit vector
countBits :: U.Vector Bit -> Int
countBits v = loop 0 0
    where
        !n = alignUp (V.length v)
        loop !s !i
            | i >= n    = s
            | otherwise = loop (s + popCount (indexWord v i)) (i + wordSize)

-- | 'True' if all bits in the vector are set
and :: U.Vector Bit -> Bool
and v = loop 0
    where
        !n = V.length v
        loop !i
            | i >= n    = True
            | otherwise = (indexWord v i == mask (n-i))
                        && loop (i + wordSize)

-- | 'True' if any bit in the vector is set
or :: U.Vector Bit -> Bool
or v = loop 0
    where
        !n = V.length v
        loop !i
            | i >= n    = False
            | otherwise = (indexWord v i /= 0)
                        || loop (i + wordSize)

all p = case (p 0, p 1) of
    (False, False) -> U.null
    (False,  True) -> allBits 1
    (True,  False) -> allBits 0
    (True,   True) -> flip seq True

any p = case (p 0, p 1) of
    (False, False) -> flip seq False
    (False,  True) -> anyBits 1
    (True,  False) -> anyBits 0
    (True,   True) -> not . U.null

allBits, anyBits :: Bit -> U.Vector Bit -> Bool
allBits 0 = not . or
allBits 1 = and

anyBits 0 = not . and
anyBits 1 = or

reverse :: U.Vector Bit -> U.Vector Bit
reverse xs = runST $ do
    let !n = V.length xs
        f i _ = return (reversePartialWord (n - i) (indexWord xs (max 0 (n - i - wordSize))))
    ys <- MV.new n
    B.mapMInPlaceWithIndex f ys
    V.unsafeFreeze ys

-- |Return the address of the first bit in the vector with the specified value, if any
first :: Bit -> U.Vector Bit -> Maybe Int
first b xs = mfilter (< n) (loop 0)
    where
        !n = V.length xs
        !ff | toBool b  = ffs
            | otherwise = ffs . complement
        
        loop !i
            | i >= n    = Nothing
            | otherwise = fmap (i +) (ff (indexWord xs i)) `mplus` loop (i + wordSize)

findIndex p xs = case (p 0, p 1) of
    (False, False) -> Nothing
    (False,  True) -> first 1 xs
    (True,  False) -> first 0 xs
    (True,   True) -> if V.null xs then Nothing else Just 0
