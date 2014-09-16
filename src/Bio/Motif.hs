{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
module Bio.Motif 
    ( PWM (..)
    , subPWM
    , rcPWM
    , Motif (..)
    , readPWM
    , scores
    , scores'
    , score
    , optimalScore
    , findTFBS
    , toIUPAC
    , readMEME
    , writeFasta
    , readFasta

    -- * References
    -- $references
    ) where

import Prelude hiding (sum)
import Bio.Utils.Misc (readDouble, readInt)
import Bio.Seq
import Control.Monad.State.Lazy
import Data.List (sortBy, foldl')
import Data.List.Split (chunksOf)
import Data.Ord (comparing)
import Data.Double.Conversion.ByteString
import Data.Default.Generics
import Data.Conduit
import qualified Data.ByteString.Char8 as B
import qualified Data.Vector.Unboxed as V
import Statistics.Matrix hiding (map)

-- | k x 4 position weight matrix for motifs
data PWM = PWM 
    { _nSites :: !(Maybe Int)  -- ^ number of sites used to generate this matrix
    , _mat :: !Matrix
    } deriving (Show)

-- | extract sub-PWM given starting position and length, zero indexed
subPWM :: Int -> Int -> PWM -> PWM
subPWM i l (PWM n (Matrix _ _ _ v)) = PWM n (fromVector l 4 v')
  where
    v' = V.slice (i * 4) (l * 4) v
{-# INLINE subPWM #-}

-- | reverse complementary of PWM
rcPWM :: PWM -> PWM
rcPWM (PWM n (Matrix nrow ncol p v)) = PWM n (Matrix nrow ncol p $ V.reverse v)
{-# INLINE rcPWM #-}

data Motif = Motif
    { _name :: !B.ByteString
    , _pwm :: !PWM
    } deriving (Show)

-- | background nucletide frequencies (A, C, G, T)
newtype BkgdModel = BG (Double, Double, Double, Double)

instance Default BkgdModel where
    def = BG (0.25, 0.25, 0.25, 0.25)

-- | convert pwm to consensus sequence, see D. R. Cavener (1987).
toIUPAC :: PWM -> DNA IUPAC
toIUPAC (PWM _ pwm) = fromBS . B.pack . map f $ toRows pwm
  where
    f v | snd a > 0.5 && snd a > 2 * snd b = fst a
        | snd a + snd b > 0.75             = iupac (fst a, fst b)
        | otherwise                        = 'N'
      where 
        [a, b, _, _] = sortBy (flip (comparing snd)) $ zip "ACGT" $ V.toList v
    iupac x = case sort' x of
        ('A', 'C') -> 'M'
        ('G', 'T') -> 'K'
        ('A', 'T') -> 'W'
        ('C', 'G') -> 'S'
        ('C', 'T') -> 'Y'
        ('A', 'G') -> 'R'
        _ -> undefined
    sort' (x, y) | x > y = (y, x)
                 | otherwise = (x, y)

-- | get scores of a long sequences at each position
scores :: BkgdModel -> PWM -> DNA a -> [Double]
scores bg p@(PWM _ pwm) dna = go $! toBS dna
  where
    go s | B.length s >= len = scoreHelp bg p (B.take len s) : go (B.tail s)
         | otherwise = []
    len = rows pwm
{-# INLINE scores #-}

-- | a streaming version of scores
scores' :: Monad m => BkgdModel -> PWM -> DNA a -> Source m Double
scores' bg p@(PWM _ pwm) dna = go 0
  where
    go i | i < n - len + 1 = do yield $ scoreHelp bg p $ B.take len $ B.drop i s
                                go (i+1)
         | otherwise = return ()
    s = toBS dna
    n = B.length s
    len = rows pwm
{-# INLINE scores' #-}

score :: BkgdModel -> PWM -> DNA a -> Double
score bg p dna = scoreHelp bg p $! toBS dna
{-# INLINE score #-}

-- | the best possible score for a pwm, assuming equal probability of nuclotides
optimalScore :: PWM -> Double
optimalScore (PWM _ pwm) = foldl' (+) 0 . map (\x -> log (V.maximum x / 0.25)) . toRows $ pwm
{-# INLINE optimalScore #-}

-- | given a user defined threshold (between 0 and 1), look for TF binding sites on a DNA 
-- sequence. This function doesn't search for binding sites on the reverse strand
findTFBS :: Monad m => Motif -> DNA a -> Double -> Source m Int
findTFBS (Motif _ pwm) dna thres = scores' def pwm dna
                                $= loop 0
  where
    loop i = do v <- await
                case v of
                    Just v' ->  if v' >= gate
                                   then yield i >> loop (i+1)
                                   else loop (i+1)
                    _ -> return ()
    gate = thres * optimalScore pwm
{-# INLINE findTFBS #-}

scoreHelp :: BkgdModel -> PWM -> B.ByteString -> Double
scoreHelp (BG (a, c, g, t)) (PWM _ pwm) dna = loop 0 0
  where
    loop !acc !x | x >= rows pwm = acc
                 | otherwise = loop (acc + f x) (x+1)
    f i = case dna `B.index` i of
              'A' -> log $! matchA / a
              'C' -> log $! matchC / c
              'G' -> log $! matchG / g
              'T' -> log $! matchT / t
              'N' -> 0
              'V' -> log $! (matchA + matchC + matchG) / (a + c + g)
              'H' -> log $! (matchA + matchC + matchT) / (a + c + t)
              'D' -> log $! (matchA + matchG + matchT) / (a + g + t)
              'B' -> log $! (matchC + matchG + matchT) / (c + g + t)
              'M' -> log $! (matchA + matchC) / (a + c)
              'K' -> log $! (matchG + matchT) / (g + t)
              'W' -> log $! (matchA + matchT) / (a + t)
              'S' -> log $! (matchC + matchG) / (c + g)
              'Y' -> log $! (matchC + matchT) / (c + t)
              'R' -> log $! (matchA + matchG) / (a + g)
              _   -> error "Bio.Motif.score: invalid nucleotide"
      where
        matchA = addSome $ unsafeIndex pwm i 0
        matchC = addSome $ unsafeIndex pwm i 1
        matchG = addSome $ unsafeIndex pwm i 2
        matchT = addSome $ unsafeIndex pwm i 3
        addSome !x | x == 0 = pseudoCount
                   | otherwise = x
        pseudoCount = 0.0001
{-# INLINE scoreHelp #-}

-- | read pwm from a matrix
readPWM :: B.ByteString -> PWM
readPWM x = PWM Nothing
              $ fromLists . map (map readDouble.B.words) . filter (not.B.null) . B.lines $ x

writePWM :: PWM -> B.ByteString
writePWM = B.unlines . map (B.unwords . map toShortest) . toLists . _mat

writeFasta :: FilePath -> [Motif] -> IO ()
writeFasta fl motifs = B.writeFile fl contents
  where
    contents = B.intercalate "" . map f $ motifs
    f x = B.unlines [">" `B.append` _name x, writePWM $ _pwm x]

readFasta :: FilePath -> IO [Motif]
readFasta fl = do contents <- B.readFile fl
                  return . map f . tail . B.split '>' $ contents
  where
    f x = let (nm, remain) = B.break (=='\n') x
          in Motif nm (readPWM remain)

readMEME :: FilePath -> IO [Motif]
readMEME = liftM fromMEME . B.readFile

fromMEME :: B.ByteString -> [Motif]
fromMEME meme = evalState (go $ B.lines meme) (0, [])
  where
    go :: [B.ByteString] -> State (Int, [B.ByteString]) [Motif]
    go (x:xs)
      | "MOTIF" `B.isPrefixOf` x = put (1, [B.drop 6 x]) >> go xs
      | otherwise = do 
          (st, str) <- get
          case st of
              1 -> do when (startOfPwm x) $ put (2, str ++ [B.words x !! 7])
                      go xs
              2 -> let x' = B.dropWhile (== ' ') x
                   in if B.null x'
                         then do put (0, [])
                                 r <- go xs
                                 return (toMotif str : r)
                         else put (2, str ++ [x']) >> go xs
              _ -> go xs
    go [] = do (st, str) <- get
               return [toMotif str | st == 2]
    startOfPwm = B.isPrefixOf "letter-probability matrix:"
    toMotif (name:n:xs) = Motif name pwm
      where
        pwm = PWM (Just $ readInt n) $ fromLists . map (map readDouble.B.words) $ xs
    toMotif _ = error "error"
{-# INLINE fromMEME #-}

------------------------------------------------------------------------------
-- matrix functions
toRows :: Matrix -> [Vector]
toRows (Matrix _ ncol _ v) = loop v 
  where 
    loop x | V.length x >= ncol = let (a, b) = V.splitAt ncol v
                                  in (a : loop b)
           | otherwise = []
{-# INLINE toRows #-}

fromLists :: [[Double]] -> Matrix
fromLists xs = Matrix nrow ncol 0 (V.fromList $ concat xs)
  where
    ncol = Prelude.length . head $ xs
    nrow = Prelude.length xs
{-# INLINE fromLists #-}

toLists :: Matrix -> [[Double]]
toLists (Matrix _ ncol _ v) = chunksOf ncol . V.toList $ v
{-# INLINE toLists #-}

-- $references
--
-- * Douglas R. Cavener. (1987) Comparison of the consensus sequence flanking
-- translational start sites in Drosophila and vertebrates.
-- /Nucleic Acids Research/ 15 (4): 1353–1361.
-- <doi:10.1093/nar/15.4.1353 http://nar.oxfordjournals.org/content/15/4/1353>