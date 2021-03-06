{-# LANGUAGE OverloadedStrings #-}

module Bio.RealWorld.GENCODE
    ( Gene(..)
    , readGenes
    , readGenes'
    , parseGenes
    ) where

import           Conduit
import qualified Data.ByteString.Char8 as B
import           Data.Maybe            (fromJust)
import           Data.CaseInsensitive  (CI, mk)

import           Bio.Utils.Misc        (readInt)

data Gene = Gene
    { geneName   :: !(CI B.ByteString)
    , geneId     :: !B.ByteString
    , geneChrom  :: !B.ByteString
    , geneStart  :: !Int
    , geneEnd    :: !Int
    , geneStrand :: !Bool
    } deriving (Show)

-- | Read gene information from Gencode GTF file
readGenes :: MonadResource m => FilePath -> Source m Gene
readGenes input = sourceFile input =$= parseGenes

readGenes' :: FilePath -> IO [Gene]
readGenes' input = runResourceT $ readGenes input $$ sinkList

parseGenes :: Monad m => Conduit B.ByteString m Gene
parseGenes = linesUnboundedAsciiC =$= concatMapC f
  where
    f l | B.head l == '#' || f3 /= "gene" = Nothing
        | otherwise = Just $ Gene (mk $ getField "gene_name") (getField "gene_id") f1
            (readInt f4 - 1) (readInt f5) (f7=="+")
      where
        [f1,_,f3,f4,f5,_,f7,_,f9] = B.split '\t' l
        fields = map (B.break (==' ') . strip) $ B.split ';' f9
        getField x = B.init $ B.drop 2 $ fromJust $ lookup x fields
    strip = fst . B.spanEnd isSpace . B.dropWhile isSpace
    isSpace = (== ' ')
{-# INLINE parseGenes #-}
