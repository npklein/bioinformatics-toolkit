module Main where

import           Bio.Data.Bed
import           Bio.Motif
import           Bio.Seq.IO
import           Conduit
import           Data.Default                      (def)
import           Data.Semigroup                    ((<>))
import           Data.Version                      (showVersion)
import           Options.Applicative
import           Paths_bioinformatics_toolkit_apps (version)
import           System.IO                         (stdout)
import           Text.Printf


data Options = Options
    { genomeFile :: FilePath
    , motifFile  :: FilePath
    , input      :: FilePath
    , p          :: Double
    } deriving (Show, Read)

parser :: Parser Options
parser = Options
     <$> strArgument (metavar "GENOME")
     <*> strArgument (metavar "MOTIF_MEME")
     <*> strArgument (metavar "INPUT")
     <*> option auto
           ( long "p-value"
          <> short 'p'
          <> value 1e-5
          <> metavar "P-Value"
          <> help "p-value cutoff. (default: 1e-5)" )

defaultMain :: Options -> IO ()
defaultMain opts = do
    withGenome (genomeFile opts) $ \genome -> do
        motifs <- readMEME $ motifFile opts
        (readBed $ input opts :: Source IO BED3) =$=
            motifScan genome motifs def (p opts) =$=
            getMotifScore genome motifs def =$=
            getMotifPValue Nothing motifs def $$ hWriteBed stdout

main :: IO ()
main = execParser opts >>= defaultMain
  where
    opts = info (helper <*> parser) ( fullDesc <>
        header (printf "bioinformatics-toolkit-apps-v%s" (showVersion version)) )
