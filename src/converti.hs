{-# LANGUAGE OverloadedStrings #-}

import Turtle hiding (splitDirectories,
                      replaceExtensions,
                      stdout,
                      stderr,
                      FilePath(..),
                      options,
                      option,
                      switch,
                      die
                     )
import Data.Text (pack, unpack, intercalate)
import System.FilePath.Posix
import System.Directory
import Data.Maybe (isJust)
import Options.Applicative
import Data.Aeson hiding (Options)
import System.Exit

import qualified Data.ByteString.Lazy as B

-- throughout this file we work in Text and convert to other types when needed

data UserOptions = UserOptions {
  documentoCommandOption :: Maybe String,
  collegamentoNormativaCommandOption :: Maybe Bool,
  celleComplesseCommandOption :: Maybe Bool,
  preservaCitazioniCommandOption :: Maybe Bool,
  dividiSezioniCommandOption :: Maybe Bool
  }

instance FromJSON UserOptions where
  parseJSON = withObject "UserOptions" $ \ v -> UserOptions
    <$> v .:? "documento"
    <*> v .:? "collegamento-normativa"
    <*> v .:? "celle-complesse"
    <*> v .:? "preserva-citazioni"
    <*> v .:? "dividi-sezioni"

data Options = Options {
  documentoOption :: String,
  collegamentoNormativaOption :: Bool,
  celleComplesseOption :: Bool,
  preservaCitazioniOption :: Bool,
  dividiSezioniOption :: Bool
  }

applyDefaults :: UserOptions -> Options
applyDefaults o = Options {
  documentoOption = def "documento.docx" $ documentoCommandOption o,
  collegamentoNormativaOption = def False $ collegamentoNormativaCommandOption o,
  celleComplesseOption = def False $ celleComplesseCommandOption o,
  preservaCitazioniOption = def False $ preservaCitazioniCommandOption o,
  dividiSezioniOption = def False $ dividiSezioniCommandOption o
  }

data CommandLineOptions = DirectOptions UserOptions | JsonOptions String

options = commandLineOptions <|> jsonOptions

jsonOptions :: Parser CommandLineOptions
jsonOptions = JsonOptions <$> option str (
  long "opzioni-json"
  <> help "permette di indicare un file JSON da cui leggere le opzioni di converti")

commandLineOptions :: Parser CommandLineOptions
commandLineOptions = DirectOptions <$> (UserOptions
          <$> optional (argument str (metavar "documento.ext"))
          <*> optional (switch (long "collegamento-normativa"
                               <> help "sostituisce i riferimenti alle leggi con links a Normattiva"
                               <> showDefault))
          <*> optional (switch (long "celle-complesse"
                               <> help "evita errori nelle celle di tabella complesse scrivendo righe molto lunghe"
                               <> showDefault))
          <*> optional (switch (long "preserva-citazioni"
                               <> help "evita di rimuovere le citazioni"
                               <> showDefault))
          <*> optional (switch (long "dividi-sezioni"
                               <> help "produce un file .rst per ogni capitolo"
                               <> showDefault)))

main = do
  opts <- execParser (info options fullDesc)
  userOptions <- case opts of
    DirectOptions o -> pure o
    JsonOptions json -> do
      b <- B.readFile json
      case (decode b) of
        Nothing -> die "Error parsing the JSON option file"
        Just o -> return o
  converti (applyDefaults userOptions)

-- this function is a good high-level description of the logic
converti :: Options -> IO ()
converti opts = do
  checkExecutables
  createDirectoryIfMissing True (fileToFolder d)
  copyFile d (inToCopy d)
  void $ withCurrentDirectory (fileToFolder d) (do
    mys (toRST opts (pack d))
    maybeLinker <- findExecutable (unpack linker)
    when (collegamentoNormativaOption opts && isJust maybeLinker) (do
      renameFile (unpack doc) (unpack docUnlinked)
      void $ mys (linkNormattiva opts)
      )
    when (dividiSezioniOption opts) (void $ mys makeSphinx)
    )
  where d = documentoOption opts
        mys c = shell c empty -- for readability

toRST o i = spaced [pandoc,
                    inputNameText i,
                    parseOpts o, writeOpts o,
                    "-o", doc]

makeSphinx = spaced [pandoc, doc, "-t json",
                     "|", "pandoc-to-sphinx"]

linkNormattiva o = spaced [pandoc, docUnlinked, "-t html",
                           "|", linker, "|",
                           pandoc, "-f html", "-o", doc, writeOpts o]

writeOpts :: Options -> Text
writeOpts o = makeOpts (wrap <> ["--standalone"]) writeRSTFilters
  where wrap = if (celleComplesseOption o) then ["--wrap none"] else []

parseOpts :: Options -> Text
parseOpts o = makeOpts ["--extract-media .", "-f docx+styles"] (parseOpenXMLFilters (not $ preservaCitazioniOption o))

-- for openXML parsing
parseOpenXMLFilters q = [ "filtro-didascalia",
                          "filtro-rimuovi-div"] <> -- per `-f docx+styles`
                        quotes :: [Text]
  where quotes = if q then ["filtro-quotes"] else []
-- for rST writing
writeRSTFilters = ["filtro-stile-liste" ] :: [Text]
allFilters = parseOpenXMLFilters True <> writeRSTFilters

checkExecutables = do
  maybeExecutables <- sequence $ map findExecutable allFilters'
  maybeNotify (dropWhile isJust maybeExecutables)
    where allFilters' = map unpack allFilters

maybeNotify []       = pure ()
maybeNotify missing  = print (errore $ head missing)
  where errore c = "`converti` si basa sui filtri di Docs Italia che non sono disponibili sul tuo sistema. Puoi installarli seguendo le istruzioni che trovi su https://github.com/italia/docs-italia-pandoc-filters"
  -- where errore c = "`converti` si basa sul comando " <> c <> " che non è disponibile sul tuo sistema. Puoi installarlo seguendo le istruzioni che trovi su https://github.com/italia/docs-italia-pandoc-filters"

maybeHead [] = Nothing
maybeHead l = Just (head l)

-- default
def :: a -> Maybe a -> a
def d Nothing = d
def d (Just something) = something

headDefault d = def d . maybeHead

makeOpts opts filters = spaced (opts <> map addFilter filters)

addFilter :: Text -> Text
addFilter f = "--filter " <> f

-- | convert the input file to the output folder
--
-- >>> fileToFolder "somedir/otherdir/file.ext"
-- "risultato-conversione/otherdir/file"
-- >>> fileToFolder "file.ext"
-- "risultato-conversione/file"
fileToFolder i = case maybeParent of
  Nothing -> joinPath [res, baseName]
  Just parent -> joinPath [res, parent, baseName]
  where res = "risultato-conversione"
        baseName = takeBaseName i
        maybeParent = maybeHead $ drop 1 $ reverse $ splitDirectories i

-- | move the input file to the destination folder
--
-- >>> inputName "somedir/otherdir/file.ext"
-- "originale.ext"
inputName :: FilePath -> FilePath
inputName i = addExtension "originale" (takeExtension i)
-- | move the input file to the destination folder
--
-- >>> inToCopy "somedir/otherdir/file.ext"
-- "risultato-conversione/otherdir/file/originale.ext"
inToCopy :: FilePath -> FilePath
inToCopy i = joinPath [fileToFolder i, inputName i]
-- | convert the input file to the output file
--
-- >>> inToOut "newExt"
-- "document.newExt"
inToOut :: FilePath -> FilePath
inToOut = addExtension "document"
-- | useful for creating commands
--
-- >>> spaced ["command", "--option", "argument"]
-- "command --option argument"
spaced :: [Text] -> Text
spaced = intercalate " "

-- paths
--
linker = "xmLeges-Linker-1.13a.exe" :: Text
doc = "documento.rst" :: Text
-- the following are for troubleshooting
docUnlinked = "documento-senza-collegamenti.rst" :: Text
-- change to switch the executable name everywhere, useful to quickly
-- test forks or different versions
pandoc = "pandoc" :: Text

inputNameText = textify inputName

textify :: (String -> String) -> Text -> Text
textify f = pack . f . unpack

