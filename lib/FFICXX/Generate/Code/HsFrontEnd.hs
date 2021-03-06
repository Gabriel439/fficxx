{-# LANGUAGE RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Code.Cpp
-- Copyright   : (c) 2011-2013 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Code.HsFrontEnd where

import Control.Monad.State
import Control.Monad.Reader
import Data.Char (toLower)
import Data.List
import qualified Data.Map as M
import Data.Maybe
import System.FilePath ((<.>))
-- 
import FFICXX.Generate.Type.Class
import FFICXX.Generate.Type.Annotate
import FFICXX.Generate.Type.Module
import FFICXX.Generate.Util


mkComment :: Int -> String -> String
mkComment indent str 
  | (not.null) str = 
    let str_lines = lines str
        indentspace = replicate indent ' ' 
        commented_lines = 
          (indentspace ++ "-- | "++head str_lines) : map (\x->indentspace ++ "--   "++x) (tail str_lines)
     in unlines commented_lines 
  | otherwise = str                

mkPostComment :: String -> String
mkPostComment str 
  | (not.null) str = 
    let str_lines = lines str 
        commented_lines = 
          ("-- ^ "++head str_lines) : map (\x->"--   "++x) (tail str_lines)
     in unlines commented_lines 
  | otherwise = str                

                        
----------------

-- |
hsModuleDeclTmpl :: String 
hsModuleDeclTmpl = "module $moduleName$ $moduleExp$ where"

-- |
genModuleDecl :: Module -> Reader AnnotateMap String 
genModuleDecl m = do 
  let modheader = render hsModuleDeclTmpl [ ("moduleName", module_name m) 
                                          , ("moduleExp", mkModuleExports m) ] 
  return (modheader)


----------------
-- |
classprefix :: Class -> String 
classprefix c = let ps = (map typeclassName . class_parents) c
                in  if null ps 
                    then "" 
                    else "(" ++ intercalate "," (map (++ " a") ps) ++ ") => "

-- |
hsClassDeclHeaderTmpl :: String
hsClassDeclHeaderTmpl = "$classann$\nclass $constraint$$classname$ a where"

genHsFrontDecl :: Class -> Reader AnnotateMap String 
genHsFrontDecl c = do 
  amap <- ask  
  let cann = maybe "" id $ M.lookup (PkgClass,class_name c) amap 
  let header = render hsClassDeclHeaderTmpl [ ("classname", typeclassName c ) 
                                            , ("constraint", classprefix c) 
                                            , ("classann",   mkComment 0 cann) ] 
      bodyline func = 
        let fname = hsFuncName c func 
            mann = maybe "" id $ M.lookup (PkgMethod,fname) amap
        in  render hsClassDeclFuncTmpl 
                                    [ ("funcname", hsFuncName c func) 
                                    , ("args" , prefixstr func ++ argstr func )
                                    , ("funcann", mkComment 4 mann)  
                                    ] 
      prefixstr func =  
        let prefixlst = (snd . mkHsFuncArgType . genericFuncArgs) func
                        ++ (snd . mkHsFuncRetType . genericFuncRet ) func
        in  if null prefixlst
              then "" 
              else "(" ++ (intercalateWith conncomma id prefixlst) ++ ") => "  
                  
      argstr func = intercalateWith connArrow id $
                      [ "a" ] 
                      ++ fst (mkHsFuncArgType (genericFuncArgs func))
                      ++ ["IO " ++ (fst . mkHsFuncRetType . genericFuncRet) func]  
      bodylines = map bodyline . virtualFuncs 
                      $ (class_funcs c) 
  return $ intercalateWith connRet id (header : bodylines) 



genAllHsFrontDecl :: [Class] -> Reader AnnotateMap String 
genAllHsFrontDecl = intercalateWithM connRet2 genHsFrontDecl

-------------------


genHsFrontInst :: Class -> Class -> String 
genHsFrontInst parent child  
  | (not.isAbstractClass) child = 
    let headline = "instance " ++ typeclassName parent ++ " " ++ (fst.hsClassName) child ++ " where" 
        defline func = "  " ++ hsFuncName child func ++ " = " ++ hsFuncXformer func ++ " " ++ hscFuncName child func 
        deflines = (map defline) . virtualFuncs . class_funcs $ parent 

    in  intercalateWith connRet id (headline : deflines) 
  | otherwise = ""
        

      
---------------------

hsClassInstExistCommonTmpl :: String 
hsClassInstExistCommonTmpl = "instance FPtr (Exist $highname$) where\n  type Raw (Exist $highname$) = $rawname$\n  get_fptr ($existConstructor$ obj) = castForeignPtr (get_fptr obj)\n  cast_fptr_to_obj fptr = $existConstructor$ (cast_fptr_to_obj (fptr :: ForeignPtr $rawname$) :: $highname$)" 


genHsFrontInstExistCommon :: Class -> String 
genHsFrontInstExistCommon c = render hsClassInstExistCommonTmpl tmplName
  where (highname,rawname) = hsClassName c
        iname = typeclassName c 
        ename = existConstructorName c
        tmplName = [ ("rawname",rawname)
                   , ("highname",highname)
                   , ("interfacename",iname)
                   , ("existConstructor",ename)
                   ] 

genAllHsFrontInstExistCommon :: [Class] -> String 
genAllHsFrontInstExistCommon cs = intercalateWith connRet2 genHsFrontInstExistCommon cs

-------------------

hsClassInstExistVirtualTmpl :: String 
hsClassInstExistVirtualTmpl = "instance $Iparent$ (Exist $child$) where\n$method$"

hsClassInstExistVirtualMethodNoSelfTmpl :: String 
hsClassInstExistVirtualMethodNoSelfTmpl = "  $methodname$ ($exist$ x) = $methodname$ x"

hsClassInstExistVirtualMethodSelfTmpl :: String 
hsClassInstExistVirtualMethodSelfTmpl = "  $methodname$ ($exist$ x) $args$ = return . $exist$ =<< $methodname$ x $args$"


genHsFrontInstExistVirtual :: Class -> Class -> String 
genHsFrontInstExistVirtual p c = render hsClassInstExistVirtualTmpl tmplName
  where methodstr = intercalateWith connRet (genHsFrontInstExistVirtualMethod p c)  
                                            (virtualFuncs.class_funcs $ p)
        tmplName = [ ("Iparent",typeclassName p)
                   , ("child", (fst.hsClassName) c)
                   , ("method", methodstr )
                   ] 

genHsFrontInstExistVirtualMethod :: Class -> Class -> Function -> String 
genHsFrontInstExistVirtualMethod p c f =
    case f of
      Constructor _  _ -> error "error in genHsFrontInstExistVirtualMethod"  
      Destructor _ -> render hsClassInstExistVirtualMethodNoSelfTmpl tmplName
      _ -> case func_ret f of
             SelfType -> render hsClassInstExistVirtualMethodSelfTmpl (tmplName++args)
             _ -> render hsClassInstExistVirtualMethodNoSelfTmpl tmplName
  where tmplName = [ ("methodname", hsFuncName p f)
                   , ("exist", existConstructorName c) ]
        args  = [ ("args", intercalate " " (take (length (func_args f)) (map (\x -> 'a':(show x)) ([1..] :: [Int]) )))]

genAllHsFrontInstExistVirtual :: [Class] -> DaughterMap -> String 
genAllHsFrontInstExistVirtual cs _dmap = intercalateWith connRet2 allinstances cs
  where allinstances c = 
          let ps = c : class_allparents c
          in  intercalateWith connRet2 (\p->genHsFrontInstExistVirtual p c) ps 


---------------------

genHsFrontInstNew :: Class         -- ^ only concrete class 
                    -> Reader AnnotateMap (Maybe String)
genHsFrontInstNew c = do 
  amap <- ask 
  if null newfuncs 
    then return Nothing
    else do 
      let newfunc = head newfuncs
          cann = maybe "" id $ M.lookup (PkgMethod, constructorName c) amap
          newfuncann = mkComment 0 cann
          newlinehead = constructorName c ++ " :: " ++ argstr newfunc 
          newlinebody = constructorName c ++ " = " 
                              ++ hsFuncXformer newfunc ++ " " 
                              ++ hscFuncName c newfunc 
          argstr func = intercalateWith connArrow id $
                          map (ctypToHsTyp (Just c) . fst) (genericFuncArgs func)
                          ++ ["IO " ++ (ctypToHsTyp (Just c) . genericFuncRet) func]
          newline = newfuncann ++ "\n" ++ newlinehead ++ "\n" ++ newlinebody 
      return (Just newline)
  where newfuncs = filter isNewFunc (class_funcs c)  

genAllHsFrontInstNew :: [Class]    -- ^ only concrete class 
                     -> Reader AnnotateMap String 
genAllHsFrontInstNew = liftM (intercalate "\n\n") . liftM catMaybes . mapM genHsFrontInstNew 
  
genHsFrontInstNonVirtual :: Class -> Maybe String 
genHsFrontInstNonVirtual c 
  | (not.null) nonvirtualFuncs  =                        
    let header f = (aliasedFuncName c f) ++ " :: " ++ argstr f
        body f  = (aliasedFuncName c f)  ++ " = " ++ hsFuncXformer f ++ " " ++ hscFuncName c f 
        argstr func = intercalateWith connArrow id $ 
                        [(fst.hsClassName) c]  
                        ++ map (ctypToHsTyp (Just c) . fst) (genericFuncArgs func)
                        ++ ["IO " ++ (ctypToHsTyp (Just c) . genericFuncRet) func] 
    in  Just $ intercalateWith connRet2 (\f -> header f ++ "\n" ++ body f) nonvirtualFuncs
  | otherwise = Nothing   
 where nonvirtualFuncs = nonVirtualNotNewFuncs (class_funcs c)

genAllHsFrontInstNonVirtual :: [Class] -> String 
genAllHsFrontInstNonVirtual = intercalate "\n\n" . map fromJust . filter isJust . map genHsFrontInstNonVirtual

-----

genHsFrontInstStatic :: Class -> Maybe String 
genHsFrontInstStatic c 
  | (not.null) fs =                        
    let header f = (aliasedFuncName c f) ++ " :: " ++ argstr f
        body f  = (aliasedFuncName c f)  ++ " = " ++ hsFuncXformer f ++ " " ++ hscFuncName c f 
        argstr f = intercalateWith connArrow id $ 
                     map (ctypToHsTyp (Just c) . fst) (genericFuncArgs f)
                     ++ ["IO " ++ (ctypToHsTyp (Just c) . genericFuncRet) f] 
    in  Just $ intercalateWith connRet2 (\f -> header f ++ "\n" ++ body f) fs
  | otherwise = Nothing   
 where fs = staticFuncs (class_funcs c)

-----

genHsFrontInstCastable :: Class -> String 
genHsFrontInstCastable c 
  | (not.isAbstractClass) c = 
    let iname = typeclassName c
        (_,rname) = hsClassName c
    in  render hsInterfaceCastableInstanceTmpl 
               [("interfaceName",iname),("rawClassName",rname)]
  | otherwise = "" 

genAllHsFrontInstCastable :: [Class] -> String 
genAllHsFrontInstCastable = 
  intercalateWith connRet2 genHsFrontInstCastable

genHsFrontInstCastableSelf :: Class -> String 
genHsFrontInstCastableSelf c 
  | (not.isAbstractClass) c = 
    let (cname,rname) = hsClassName c
    in  render hsInterfaceCastableInstanceSelfTmpl 
               [("className",cname)
               ,("rawClassName",rname)]
  | otherwise = "" 


--------------------------

rawToHighDecl :: String
rawToHighDecl = "data $rawname$\nnewtype $highname$ = $highname$ (ForeignPtr $rawname$) deriving (Eq, Ord, Show)"

rawToHighInstance :: String
rawToHighInstance = "instance FPtr $highname$ where\n   type Raw $highname$ = $rawname$\n   get_fptr ($highname$ fptr) = fptr\n   cast_fptr_to_obj = $highname$"


existableInstance :: String 
existableInstance = "instance Existable $highname$ where\n  data Exist $highname$ = forall a. (FPtr a, $interfacename$ a) => $existConstructor$ a"


hsClassRawType :: Class -> String 
hsClassRawType c = 
    let decl = render rawToHighDecl tmplName
        inst1 = render rawToHighInstance tmplName
    in  decl `connRet` inst1 
  where (highname,rawname) = hsClassName c
        iname = typeclassName c 
        -- ename = existConstructorName c
        tmplName = [ ("rawname",rawname)
                   , ("highname",highname)
                   , ("interfacename",iname)
                   ] 

hsClassExistType :: Class -> String 
hsClassExistType c = render existableInstance tmplName
  where (highname,_rawname) = hsClassName c
        iname = typeclassName c 
        ename = existConstructorName c
        tmplName = [ ("existConstructor",ename) 
                   , ("highname",highname)
                   , ("interfacename",iname)
                   ]

hsClassDeclFuncTmpl :: String
hsClassDeclFuncTmpl = "$funcann$\n    $funcname$ :: $args$ "


hsArgs :: Class -> Args -> String
hsArgs c = intercalateWith connArrow (ctypToHsTyp (Just c) . fst) 

mkHsFuncArgType :: Args -> ([String],[String]) 
mkHsFuncArgType lst = 
  let  (args,st) = runState (mapM mkFuncArgTypeWorker lst) ([],(0 :: Int))
  in   (args,fst st)
  where mkFuncArgTypeWorker (typ,_var) = 
          case typ of                  
            SelfType -> return "a"
            CT _ _   -> return $ ctypToHsTyp Nothing typ 
            CPT (CPTClass c') _ -> do 
              (prefix,n) <- get 
              let cname = (fst.hsClassName) c' 
                  iname = typeclassNameFromStr cname 
                  newname = 'c' : show n
                  newprefix1 = iname ++ " " ++ newname    
                  newprefix2 = "FPtr " ++ newname
              put (newprefix1:newprefix2:prefix,n+1)
              return newname
            CPT (CPTClassRef c') _ -> do 
              (prefix,n) <- get 
              let cname = (fst.hsClassName) c' 
                  iname = typeclassNameFromStr cname 
                  newname = 'c' : show n
                  newprefix1 = iname ++ " " ++ newname    
                  newprefix2 = "FPtr " ++ newname
              put (newprefix1:newprefix2:prefix,n+1)
              return newname
            _ -> error ("No such c type : " ++ show typ)  

mkHsFuncRetType :: Types -> (String,[String])
mkHsFuncRetType rtyp = 
  case rtyp of 
    SelfType -> ("a",[])
    CPT (CPTClass c') _ -> (cname,[]) where cname = (fst.hsClassName) c' 
    CPT (CPTClassRef c') _ -> (cname,[]) where cname = (fst.hsClassName) c' 
    _ -> (ctypToHsTyp Nothing rtyp,[])

      
----------                        

hsInterfaceCastableInstanceTmpl :: String 
hsInterfaceCastableInstanceTmpl = 
  "instance ($interfaceName$ a, FPtr a) => Castable a (Ptr $rawClassName$) where\n  cast = unsafeForeignPtrToPtr . castForeignPtr . get_fptr\n  uncast = cast_fptr_to_obj . castForeignPtr . unsafePerformIO . newForeignPtr_ \n"

hsInterfaceCastableInstanceSelfTmpl :: String 
hsInterfaceCastableInstanceSelfTmpl = 
  "instance Castable $className$ (Ptr $rawClassName$) where\n  cast = unsafeForeignPtrToPtr . castForeignPtr . get_fptr\n  uncast = cast_fptr_to_obj . castForeignPtr . unsafePerformIO . newForeignPtr_ \n"


----------

hsExistentialGADTBodyTmpl :: String 
hsExistentialGADTBodyTmpl = "    GADT$mother$$daughter$ :: $daughter$ -> GADTType $mother$ $daughter$"


hsExistentialCastBodyTmpl :: String
hsExistentialCastBodyTmpl = "    \"$daughter$\" -> case obj of\n        $mother$ fptr -> let obj' = $daughter$ (castForeignPtr fptr :: ForeignPtr Raw$daughter$)\n                        in  return . EGADT$mother$ . GADT$mother$$daughter$ \\$ obj'"

------------
-- upcast --
------------

genHsFrontUpcastClass :: Class -> Reader AnnotateMap String
genHsFrontUpcastClass c = do 
  -- amap <- ask 
  let (highname,rawname) = hsClassName c
      upcaststr = render hsUpcastClassTmpl [ ("classname", highname) 
                                           , ("ifacename", typeclassName c)
                                           , ("rawclassname", rawname)  
                                           , ("space", replicate (length highname+11) ' ' ) ] 
  return upcaststr

genAllHsFrontUpcastClass :: [Class] -> Reader AnnotateMap String
genAllHsFrontUpcastClass = intercalateWithM connRet2 genHsFrontUpcastClass


hsUpcastClassTmpl :: String 
hsUpcastClassTmpl =  "upcast$classname$ :: (FPtr a, $ifacename$ a) => a -> $classname$\nupcast$classname$ h = let fh = get_fptr h\n$space$    fh2 :: ForeignPtr $rawclassname$ = castForeignPtr fh\n$space$in cast_fptr_to_obj fh2"


--------------
-- downcast --
--------------

genHsFrontDowncastClass :: Class -> Reader AnnotateMap String
genHsFrontDowncastClass c = do 
  let (highname,rawname) = hsClassName c
      downcaststr = render hsDowncastClassTmpl [ ("classname", highname) 
                                               , ("ifacename", typeclassName c)
                                               , ("rawclassname", rawname)  
                                               , ("space", replicate (length highname+13) ' ' ) ] 
  return downcaststr

genAllHsFrontDowncastClass :: [Class] -> Reader AnnotateMap String
genAllHsFrontDowncastClass = intercalateWithM connRet2 genHsFrontDowncastClass


hsDowncastClassTmpl :: String 
hsDowncastClassTmpl =  "downcast$classname$ :: (FPtr a, $ifacename$ a) => $classname$ -> a \ndowncast$classname$ h = let fh = get_fptr h\n$space$    fh2 = castForeignPtr fh\n$space$in cast_fptr_to_obj fh2"

------------
-- Export --
------------

genExport :: Class -> String 
genExport c =
    let methodstr = if null . (filter isVirtualFunc) $ (class_funcs c) 
                      then ""
                      else "(..)"
    in if isAbstractClass c 
         then "    " ++ typeclassName c ++ methodstr 
         else "    " ++ (fst.hsClassName) c ++ "(..)\n  , " 
                     ++ typeclassName c ++ methodstr
                     ++ "\n  , upcast" ++ (fst.hsClassName) c 
                     ++ "\n  , downcast" ++ (fst.hsClassName) c 
                     ++ "\n" ++ genExportConstructorAndNonvirtual c 
                     ++ "\n" ++ genExportStatic c 

-- | constructor and non-virtual function 
genExportConstructorAndNonvirtual :: Class -> String 
genExportConstructorAndNonvirtual c =         
    intercalateWith connRet (\x->indent++", "++x) fns
  where indent = replicate 2 ' ' 
        fs = class_funcs c
        fns = map (aliasedFuncName c) (constructorFuncs fs 
                                       ++ nonVirtualNotNewFuncs fs)

-- | staic function export list 
genExportStatic :: Class -> String 
genExportStatic c =         
    intercalateWith connRet (\x->indent++", "++x) fns
  where indent = replicate 2 ' ' 
        fs = class_funcs c
        fns = map (aliasedFuncName c) (staticFuncs fs) 





genExportList :: [Class] -> String 
genExportList = concatMap genExport 

importOneClass :: String -> String -> String 
importOneClass mname typ = "import " ++ mname <.> typ 

importSOURCEOneClass :: String -> String -> String 
importSOURCEOneClass mname typ = "import {-# SOURCE #-} " ++ mname <.> typ 


genImportInModule :: [Class] -> String 
genImportInModule cs = 
  let genImportOneClass c = 
        let n = getClassModuleBase c 
        in  intercalateWith connRet (importOneClass n) $
              ["RawType", "Interface", "Implementation"]
  in  intercalate "\n" (map genImportOneClass cs)


genImportInFFI :: ClassModule -> String
genImportInFFI m = 
  let modlst = cmImportedModulesForFFI m
  in  intercalateWith connRet (\x->importOneClass x "RawType") modlst


genImportInInterface :: ClassModule -> String
genImportInInterface m = 
  let modlstraw = cmImportedModulesRaw m
      modlstparent = cmImportedModulesHighNonSource m 
      modlsthigh = cmImportedModulesHighSource m
      getImportOneClassRaw mname = 
        intercalateWith connRet (importOneClass mname) ["RawType"]
      getImportOneClassHigh mname = 
        intercalateWith connRet (importOneClass mname) ["Interface"]
      getImportSOURCEOneClassHigh mname = 
        intercalateWith connRet (importSOURCEOneClass mname) ["Interface"]
  in  importOneClass (cmModule m) "RawType"
      `connRet`
      intercalateWith connRet getImportOneClassRaw modlstraw
      `connRet`
      intercalateWith connRet getImportOneClassHigh modlstparent 
      `connRet` 
      "---- ============ ----" 
      `connRet` 
      intercalateWith connRet getImportSOURCEOneClassHigh modlsthigh

-- |
genImportInCast :: ClassModule -> String 
genImportInCast m = 
    importOneClass (cmModule m) "RawType"
    `connRet` 
    importOneClass (cmModule m) "Interface"

-- | 
genImportInImplementation :: ClassModule -> String
genImportInImplementation m = 
  let modlstraw' = cmImportedModulesForFFI m
      modlsthigh = nub $ map getClassModuleBase $ concatMap class_allparents (cmClass m)
      modlstraw = filter (not.(flip elem modlsthigh)) modlstraw' 
      getImportOneClassRaw mname = 
        intercalateWith connRet (importOneClass mname) 
                        ["RawType","Cast","Interface"]
      getImportOneClassHigh mname = 
        intercalateWith connRet (importOneClass mname) 
                        ["RawType","Cast","Interface"] 
  in  importOneClass (cmModule m) "RawType"
      `connRet`
      importOneClass (cmModule m) "FFI"
      `connRet`
      importOneClass (cmModule m) "Interface"
      `connRet`
      importOneClass (cmModule m) "Cast"
      `connRet`
      intercalateWith connRet getImportOneClassRaw modlstraw
      `connRet` 
      intercalateWith connRet getImportOneClassHigh modlsthigh

-- | 
genImportInExistential :: DaughterMap -> ClassModule -> String
genImportInExistential dmap m = 
  let daughters = concat . catMaybes $ (map (flip M.lookup dmap . getClassModuleBase)  (cmClass m))
      alldaughters' = nub . map getClassModuleBase $ daughters
      -- alldaughters = filter ((&&) <$> (/= "TClass") <*> (/= "TObject")) alldaughters'
      alldaughters = alldaughters'
      getImportOneClass mname = 
          intercalateWith connRet (importOneClass mname) 
                          ["RawType", "Cast", "Interface", "Implementation"]
  in  intercalateWith connRet getImportOneClass alldaughters




------------------------
-- Top Level Function --
------------------------

genTopLevelFuncDef :: TopLevelFunction -> String 
genTopLevelFuncDef f@TopLevelFunction {..} = 
    let fname = hsFrontNameForTopLevelFunction f
        cfname = "c_" ++ toLowers fname 
        args = toplevelfunc_args
        ret = toplevelfunc_ret 
        xformerstr = let len = length args in if len > 0 then "xform" ++ show (len-1) else "xformnull"
        prefixstr =  
          let prefixlst = (snd . mkHsFuncArgType) toplevelfunc_args
                        ++ (snd . mkHsFuncRetType) toplevelfunc_ret
          in  if null prefixlst
              then "" 
              else "(" ++ (intercalateWith conncomma id prefixlst) ++ ") => "  

        argstr = intercalateWith connArrow id $
                      (fst . mkHsFuncArgType) toplevelfunc_args 
                      ++ ["IO " ++ (fst . mkHsFuncRetType) toplevelfunc_ret]  
        defstr = fname ++ " = " ++ xformerstr ++ " " ++ cfname
    in fname ++ " :: " ++ prefixstr ++ argstr ++ "\n" ++ defstr 
genTopLevelFuncDef v@TopLevelVariable {..} = 
    let fname = hsFrontNameForTopLevelFunction v
        cfname = "c_" ++ toLowers fname 
        args = []
        ret = toplevelvar_ret 
        xformerstr = let len = length args in if len > 0 then "xform" ++ show (len-1) else "xformnull"
        prefixstr =  
          let prefixlst = (snd . mkHsFuncRetType) toplevelvar_ret
          in  if null prefixlst
              then "" 
              else "(" ++ (intercalateWith conncomma id prefixlst) ++ ") => "  

        argstr = intercalateWith connArrow id $ ["IO " ++ (fst . mkHsFuncRetType) toplevelvar_ret]  
        defstr = fname ++ " = " ++ xformerstr ++ " " ++ cfname
    in fname ++ " :: " ++ prefixstr ++ argstr ++ "\n" ++ defstr 

