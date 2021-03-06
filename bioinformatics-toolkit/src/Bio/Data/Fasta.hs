{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}

module Bio.Data.Fasta
    ( FastaLike(..)
    , fastaReader
    ) where

import Bio.Motif
import Bio.Seq
import qualified Data.ByteString.Char8 as B
import Conduit

class FastaLike f where
    -- | Convert a FASTA record, consisting of a record header and a record body,
    -- to a specific data type
    fromFastaRecord :: (B.ByteString, [B.ByteString]) -> f

    readFasta :: FilePath -> Source (ResourceT IO) f
    readFasta fl = fastaReader fl =$= mapC fromFastaRecord

    -- | non-stream version, read whole file in memory
    readFasta' :: FilePath -> IO [f]
    readFasta' fl = runResourceT $ readFasta fl $$ sinkList
    {-# MINIMAL fromFastaRecord #-}

instance BioSeq s a => FastaLike (s a) where
    fromFastaRecord (_, xs) = fromBS . B.concat $ xs
    {-# INLINE fromFastaRecord #-}

instance FastaLike Motif where
    fromFastaRecord (name, mat) = Motif name (toPWM mat)
    {-# INLINE fromFastaRecord #-}

fastaReader :: FilePath -> Source (ResourceT IO) (B.ByteString, [B.ByteString])
fastaReader fl = sourceFile fl =$= linesUnboundedAsciiC =$= loop []
  where
    loop acc = do
        x <- await
        case x of
            Just l -> case () of
                _ | B.null l -> loop acc  -- empty line, go to next line
                  | B.head l == '>' -> output (reverse acc) >> loop [B.tail l]
                  | otherwise -> loop (l:acc)
            Nothing -> output $ reverse acc
    output (x:xs) = yield (x, xs)
    output _ = return ()
{-# INLINE fastaReader #-}
