{-# LANGUAGE OverloadedStrings #-}
module Cheapskate.Parse (
         markdown
       ) where
import Cheapskate.ParserCombinators
import Cheapskate.Util
import Cheapskate.Inlines
import Cheapskate.Types
import Data.Char hiding (Space)
import qualified Data.Set as Set
import Prelude hiding (takeWhile)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Monoid
import Data.Foldable (toList)
import Data.Sequence ((|>), viewr, ViewR(..), singleton, Seq)
import qualified Data.Sequence as Seq
import Control.Monad.RWS
import Control.Applicative
import qualified Data.Map as M
import Data.List (intercalate)

import Debug.Trace

markdown :: Options -> Text -> Doc
markdown opts
  | debug opts = (\x -> trace (show x) $ Doc opts mempty) . processLines
  | otherwise  = Doc opts . processDocument . processLines

-- container stack:

data ContainerStack =
  ContainerStack Container {- top -} [Container] {- rest -}

type LineNumber   = Int

data Elt = C Container
         | L LineNumber Leaf
         deriving Show

data Container = Container{
                     containerType :: ContainerType
                   , children      :: Seq Elt
                   }

data ContainerType = Document
                   | BlockQuote
                   | ListItem { markerColumn :: Int
                              , padding      :: Int
                              , listType     :: ListType }
                   | FencedCode { startColumn :: Int
                                , fence :: Text
                                , info :: Text }
                   | IndentedCode
                   | RawHtmlBlock
                   | Reference
                   deriving (Eq, Show)

instance Show Container where
  show c = show (containerType c) ++ "\n" ++
    nest 2 (intercalate "\n" (map showElt $ toList $ children c))

nest :: Int -> String -> String
nest num = intercalate "\n" . map ((replicate num ' ') ++) . lines

showElt :: Elt -> String
showElt (C c) = show c
showElt (L _ (TextLine s)) = show s
showElt (L _ lf) = show lf

containerContinue :: Container -> Scanner
containerContinue c =
  case containerType c of
       BlockQuote     -> scanNonindentSpace *> scanBlockquoteStart
       IndentedCode   -> scanIndentSpace
       FencedCode{startColumn = col} ->
                         scanSpacesToColumn col
       RawHtmlBlock   -> nfb scanBlankline
       li@ListItem{}  -> scanBlankline
                         <|>
                         (do scanSpacesToColumn
                                (markerColumn li + 1)
                             upToCountChars (padding li - 1)
                                (==' ')
                             return ())
       Reference{}    -> nfb scanBlankline >>
                         nfb (scanNonindentSpace *> scanReference)
       _              -> return ()
{-# INLINE containerContinue #-}

containerStart :: Bool -> Parser ContainerType
containerStart _lastLineIsText = scanNonindentSpace *>
   (  (BlockQuote <$ scanBlockquoteStart)
  <|> parseListMarker
   )

verbatimContainerStart :: Bool -> Parser ContainerType
verbatimContainerStart lastLineIsText = scanNonindentSpace *>
   (  parseCodeFence
  <|> (guard (not lastLineIsText) *> (IndentedCode <$ char ' ' <* nfb scanBlankline))
  <|> (guard (not lastLineIsText) *> (RawHtmlBlock <$ parseHtmlBlockStart))
  <|> (guard (not lastLineIsText) *> (Reference <$ scanReference))
   )

data Leaf = TextLine Text
          | BlankLine Text
          | ATXHeader Int Text
          | SetextHeader Int Text
          | Rule
          deriving (Show)

type ContainerM = RWS () ReferenceMap ContainerStack

closeStack :: ContainerM Container
closeStack = do
  ContainerStack top rest  <- get
  if null rest
     then return top
     else closeContainer >> closeStack

closeContainer :: ContainerM ()
closeContainer = do
  ContainerStack top rest <- get
  case top of
       (Container Reference{} cs'') ->
         case parse pReference
               (T.strip $ joinLines $ map extractText $ toList cs'') of
              Right (lab, lnk, tit) -> do
                tell (M.singleton (normalizeReference lab) (lnk, tit))
                case rest of
                    (Container ct' cs' : rs) ->
                      put $ ContainerStack (Container ct' (cs' |> C top)) rs
                    [] -> return ()
              Left _ -> -- pass over in silence if ref doesn't parse?
                        case rest of
                             (c:cs) -> put $ ContainerStack c cs
                             []     -> return ()
       (Container li@ListItem{} cs'') ->
         case rest of
              -- move final BlankLine outside of list item
              (Container ct' cs' : rs) ->
                       case viewr cs'' of
                            (zs :> b@(L _ BlankLine{})) ->
                              put $ ContainerStack
                                   (if Seq.null zs
                                       then Container ct' (cs' |> C (Container li zs))
                                       else Container ct' (cs' |>
                                               C (Container li zs) |> b)) rs
                            _ -> put $ ContainerStack (Container ct' (cs' |> C top)) rs
              [] -> return ()
       _ -> case rest of
             (Container ct' cs' : rs) ->
                 put $ ContainerStack (Container ct' (cs' |> C top)) rs
             [] -> return ()

addLeaf :: LineNumber -> Leaf -> ContainerM ()
addLeaf lineNum lf = do
  ContainerStack top rest <- get
  case (top, lf) of
        (Container ct@(ListItem{}) cs, BlankLine{}) ->
          case viewr cs of
            (_ :> L _ BlankLine{}) -> -- two blanks break out of list item:
                 closeContainer >> addLeaf lineNum lf
            _ -> put $ ContainerStack (Container ct (cs |> L lineNum lf)) rest
        (Container ct cs, _) ->
                 put $ ContainerStack (Container ct (cs |> L lineNum lf)) rest

addContainer :: ContainerType -> ContainerM ()
addContainer ct = modify $ \(ContainerStack top rest) ->
  ContainerStack (Container ct mempty) (top:rest)

extractText :: Elt -> Text
extractText (L _ (TextLine t)) = t
extractText _ = mempty
processDocument :: (Container, ReferenceMap) -> Blocks
processDocument (Container ct cs, refmap) =
  case ct of
    Document -> processElts refmap (toList cs)
    _        -> error "top level container is not Document"


-- Turn the result of `processLines` into a proper AST.
-- This requires grouping text lines into paragraphs
-- and list items into lists, handling blank lines,
-- parsing inline contents of texts and resolving referencess.
processElts :: ReferenceMap -> [Elt] -> Blocks
processElts _ [] = mempty

processElts refmap (L _lineNumber lf : rest) =
  case lf of
    -- Gobble text lines and make them into a Para:
    TextLine t -> singleton (Para $ parseInlines refmap txt) <>
                  processElts refmap rest'
               where txt = T.stripEnd $ joinLines $ map T.stripStart
                           $ t : map extractText textlines
                     (textlines, rest') = span isTextLine rest
                     isTextLine (L _ (TextLine _)) = True
                     isTextLine _ = False

    -- Blanks at outer level are ignored:
    BlankLine{} -> processElts refmap rest

    -- Headers:
    ATXHeader lvl t -> singleton (Header lvl $ parseInlines refmap t) <>
                       processElts refmap rest
    SetextHeader lvl t -> singleton (Header lvl $ parseInlines refmap t) <>
                          processElts refmap rest

    -- Horizontal rule:
    Rule -> singleton HRule <> processElts refmap rest

processElts refmap (C (Container ct cs) : rest) =
  case ct of
    Document -> error "Document container found inside Document"

    BlockQuote -> singleton (Blockquote $ processElts refmap (toList cs)) <>
                  processElts refmap rest

    -- List item?  Gobble up following list items of the same type
    -- (skipping blank lines), determine whether the list is tight or
    -- loose, and generate a List.
    ListItem { listType = listType' } ->
        singleton (List isTight listType' items') <> processElts refmap rest'
              where xs = takeListItems rest
                    rest' = drop (length xs) rest
                    takeListItems (C c@(Container ListItem { listType = lt' } _)
                       : zs)
                      | listTypesMatch lt' listType' = C c : takeListItems zs
                    takeListItems (lf@(L _ (BlankLine _)) :
                             c@(C (Container ListItem { listType = lt' } _)) :
                             zs)
                      | listTypesMatch lt' listType' = lf : c : takeListItems zs
                    takeListItems _ = []
                    listTypesMatch (Bullet c1) (Bullet c2) = c1 == c2
                    listTypesMatch (Numbered w1 _) (Numbered w2 _) = w1 == w2
                    listTypesMatch _ _ = False
                    items = mapMaybe getItem (Container ct cs : [c | C c <- xs])
                    getItem (Container ListItem{} cs') = Just $ toList cs'
                    getItem _                         = Nothing
                    items' = map (processElts refmap) items
                    isTight = not (any isBlankLine xs) &&
                              all tightListItem items

    FencedCode _ _ info' -> singleton (CodeBlock attr txt) <>
                               processElts refmap rest
                  where txt = joinLines $ map extractText $ toList cs
                        attr = case T.words info' of
                                  []    -> CodeAttr Nothing
                                  (w:_) -> CodeAttr (Just w)

    IndentedCode -> singleton (CodeBlock (CodeAttr Nothing) txt)
                    <> processElts refmap rest'
                  where txt = joinLines $ stripTrailingEmpties
                              $ concatMap extractCode cbs
                        stripTrailingEmpties = reverse .
                          dropWhile (T.all (==' ')) . reverse
                        -- explanation for next line:  when we parsed
                        -- the blank line, we dropped 0-3 spaces.
                        -- but for this, code block context, we want
                        -- to have dropped 4 spaces. we simply drop
                        -- one more:
                        extractCode (L _ (BlankLine t)) = [T.drop 1 t]
                        extractCode (C (Container IndentedCode cs')) =
                          map extractText $ toList cs'
                        extractCode _ = []
                        (cbs, rest') = span isIndentedCodeOrBlank
                                       (C (Container ct cs) : rest)
                        isIndentedCodeOrBlank (L _ BlankLine{}) = True
                        isIndentedCodeOrBlank (C (Container IndentedCode _))
                                                              = True
                        isIndentedCodeOrBlank _               = False

    RawHtmlBlock -> singleton (HtmlBlock txt) <> processElts refmap rest
                  where txt = joinLines (map extractText (toList cs))

    -- References have already been taken into account in the reference map.
    Reference{} -> processElts refmap rest

   where isBlankLine (L _ BlankLine{}) = True
         isBlankLine _ = False
         tightListItem [] = True
         tightListItem xs = not $ any isBlankLine xs


processLines :: Text -> (Container, ReferenceMap)
processLines t = (doc, refmap)
  where
  (doc, refmap) = evalRWS (mapM_ processLine lns >> closeStack) () startState
  lns        = zip [1..] (map tabFilter $ T.lines t)
  startState = ContainerStack (Container Document mempty) []

-- The main block-parsing function.
-- We analyze a line of text and modify the container stack accordingly,
-- adding a new leaf, or closing or opening containers.
processLine :: (LineNumber, Text) -> ContainerM ()
processLine (lineNumber, txt) = do
  ContainerStack top@(Container ct cs) rest <- get

  -- Apply the line-start scanners appropriate for each nested container.
  -- Return the remainder of the string, and the number of unmatched
  -- containers.
  let (t', numUnmatched) = tryOldContainers (reverse $ top:rest) txt

  -- Some new containers can be started only after a blank.
  let lastLineIsText = numUnmatched == 0 &&
                       case viewr cs of
                            (_ :> L _ (TextLine _)) -> True
                            _                       -> False

  -- Process the rest of the line in a way that makes sense given
  -- the container type at the top of the stack (ct):
  case ct of
    -- If it's a verbatim line container, add the line.
    RawHtmlBlock{} | numUnmatched == 0 -> addLeaf lineNumber (TextLine t')
    IndentedCode   | numUnmatched == 0 -> addLeaf lineNumber (TextLine t')
    FencedCode{ fence = fence' } ->
    -- here we don't check numUnmatched because we allow laziness
      if fence' `T.isPrefixOf` t'
         -- closing code fence
         then closeContainer
         else addLeaf lineNumber (TextLine t')

    -- otherwise, parse the remainder to see if we have new container starts:
    _ -> case tryNewContainers lastLineIsText (T.length txt - T.length t') t' of

       ([], TextLine t) ->  -- no new containers, just a text line
         case viewr cs of
            -- if last child of top container is text line, then
            -- we don't need to close unmatched containers, because this can be
            -- a lazy continuation:
            (_ :> L _ (TextLine _))
              | ct /= IndentedCode -> addLeaf lineNumber (TextLine t)
            -- otherwise, close unmatched containers before adding the line
            _ -> replicateM numUnmatched closeContainer
                 >> addLeaf lineNumber (TextLine t)

       -- if it's a setext header line and the top container has a textline
       -- as last child, add a setext header:
       ([], SetextHeader lev _) | numUnmatched == 0 ->
           case viewr cs of
             (cs' :> L _ (TextLine t)) -> -- replace last text line with setext header
               put $ ContainerStack (Container ct
                        (cs' |> L lineNumber (SetextHeader lev t))) rest
               -- Note: the following case should not occur, since
               -- we don't add a SetextHeader leaf unless lastLineIsText.
             _ -> error "setext header line without preceding text line"

       -- otherwise, close all the unmatched containers, add the new
       -- containers, and finally add the new leaf:
       (ns, lf) -> do -- close unmatched containers, add new ones
           replicateM numUnmatched closeContainer
           mapM_ addContainer ns
           case (reverse ns, lf) of
             -- don't add extra blank at beginning of fenced code block
             (FencedCode{}:_,  BlankLine{}) -> return ()
             _ -> addLeaf lineNumber lf


tryOldContainers :: [Container] -> Text -> (Text, Int)
tryOldContainers cs t = case parse (scanners $ map containerContinue cs) t of
                        Right (t', n)  -> (t', n)
                        Left e         -> error $ "error parsing scanners: " ++
                                           show e
  where scanners [] = (,) <$> takeText <*> pure 0
        scanners (p:ps) = (p *> scanners ps)
                      <|> ((,) <$> takeText <*> pure (length (p:ps)))

tryNewContainers :: Bool -> Int -> Text -> ([ContainerType], Leaf)
tryNewContainers lastLineIsText offset t =
  case parse newContainers t of
       Right (cs,t') -> (cs, t')
       Left err      -> error (show err)
  where newContainers = do
          getPosition >>= \pos -> setPosition pos{ column = offset + 1 }
          regContainers <- many (containerStart lastLineIsText)
          verbatimContainers <- option []
                            $ count 1 (verbatimContainerStart lastLineIsText)
          if null verbatimContainers
             then (,) <$> pure regContainers <*> leaf lastLineIsText
             else (,) <$> pure (regContainers ++ verbatimContainers) <*>
                            textLineOrBlank
textLineOrBlank :: Parser Leaf
textLineOrBlank = consolidate <$> takeText
  where consolidate ts = if T.all (==' ') ts
                            then BlankLine ts
                            else TextLine ts

leaf :: Bool -> Parser Leaf
leaf lastLineIsText = scanNonindentSpace *> (
     (ATXHeader <$> parseAtxHeaderStart <*>
         (T.strip . removeATXSuffix <$> takeText))
   <|> (guard lastLineIsText *> (SetextHeader <$> parseSetextHeaderLine <*> pure mempty))
   <|> (Rule <$ scanHRuleLine)
   <|> textLineOrBlank
  )
  where removeATXSuffix t = case T.dropWhileEnd (`elem` " #") t of
                                 t' | T.null t' -> t'
                                      -- an escaped \#
                                    | T.last t' == '\\' -> t' <> "#"
                                    | otherwise -> t'

-- Scanners.

scanReference :: Scanner
scanReference =
  () <$ lookAhead (pLinkLabel >> scanChar ':')

-- Scan the beginning of a blockquote:  up to three
-- spaces indent, the `>` character, and an optional space.
scanBlockquoteStart :: Scanner
scanBlockquoteStart =
  scanChar '>' >> option () (scanChar ' ')

-- Parse the sequence of `#` characters that begins an ATX
-- header, and return the number of characters.  We require
-- a space after the initial string of `#`s, as not all markdown
-- implementations do. This is because (a) the ATX reference
-- implementation requires a space, and (b) since we're allowing
-- headers without preceding blank lines, requiring the space
-- avoids accidentally capturing a line like `#8 toggle bolt` as
-- a header.
parseAtxHeaderStart :: Parser Int
parseAtxHeaderStart = do
  char '#'
  hashes <- upToCountChars 5 (== '#')
  skip (==' ') <|> scanBlankline
  return $ T.length hashes + 1

parseSetextHeaderLine :: Parser Int
parseSetextHeaderLine = do
  d <- char '-' <|> char '='
  let lev = if d == '=' then 1 else 2
  many (char d)
  scanBlankline
  return lev

-- Scan a horizontal rule line: "...three or more hyphens, asterisks,
-- or underscores on a line by themselves. If you wish, you may use
-- spaces between the hyphens or asterisks."
scanHRuleLine :: Scanner
scanHRuleLine = do
  c <- satisfy $ inClass "*_-"
  count 2 $ scanSpaces >> char c
  skipWhile (\x -> x == ' ' || x == c)
  endOfInput

-- Parse an initial code fence line, returning
-- the fence part and the rest (after any spaces).
parseCodeFence :: Parser ContainerType
parseCodeFence = do
  col <- column <$> getPosition
  c <- satisfy $ inClass "`~"
  count 2 (char c)
  extra <- takeWhile (== c)
  scanSpaces
  rawattr <- takeWhile (/='`')
  endOfInput
  return $ FencedCode { startColumn = col
                      , fence = T.pack [c,c,c] <> extra
                      , info = rawattr }

-- Parse the start of an HTML block:  either an HTML tag or an
-- HTML comment, with no indentation.
parseHtmlBlockStart :: Parser ()
parseHtmlBlockStart = () <$ lookAhead
     ((do t <- pHtmlTag
          guard $ f $ fst t
          return $ snd t)
    <|> string "<!--"
    <|> string "-->"
     )
 where f (Opening name) = name `Set.member` blockHtmlTags
       f (SelfClosing name) = name `Set.member` blockHtmlTags
       f (Closing name) = name `Set.member` blockHtmlTags

-- List of block level tags for HTML 5.
blockHtmlTags :: Set.Set Text
blockHtmlTags = Set.fromList
 [ "article", "header", "aside", "hgroup", "blockquote", "hr",
   "body", "li", "br", "map", "button", "object", "canvas", "ol",
   "caption", "output", "col", "p", "colgroup", "pre", "dd",
   "progress", "div", "section", "dl", "table", "dt", "tbody",
   "embed", "textarea", "fieldset", "tfoot", "figcaption", "th",
   "figure", "thead", "footer", "footer", "tr", "form", "ul",
   "h1", "h2", "h3", "h4", "h5", "h6", "video"]


-- Parse a list marker and return the list type.
parseListMarker :: Parser ContainerType
parseListMarker = do
  col <- column <$> getPosition
  ty <- parseBullet <|> parseListNumber
  padding' <- (1 <$ scanBlankline)
          <|> (1 <$ (skip (==' ') *> lookAhead (count 4 (char ' '))))
          <|> (T.length <$> takeWhile (==' '))
  guard $ padding' > 0
  return $ ListItem { listType = ty
                    , markerColumn = col
                    , padding = padding' + listMarkerWidth ty
                    }

listMarkerWidth :: ListType -> Int
listMarkerWidth (Bullet _) = 1
listMarkerWidth (Numbered _ n) | n < 10    = 2
                               | n < 100   = 3
                               | n < 1000  = 4
                               | otherwise = 5

-- Parse a bullet and return list type.
parseBullet :: Parser ListType
parseBullet = do
  c <- satisfy $ inClass "+*-"
  unless (c == '+')
    $ nfb $ (count 2 $ scanSpaces >> skip (== c)) >>
          skipWhile (\x -> x == ' ' || x == c) >> endOfInput -- hrule
  return $ Bullet c

-- Parse a list number marker and return list type.
parseListNumber :: Parser ListType
parseListNumber = do
    num <- (read . T.unpack) <$> takeWhile1 isDigit
    wrap <-  PeriodFollowing <$ skip (== '.')
         <|> ParenFollowing <$ skip (== ')')
    return $ Numbered wrap num


