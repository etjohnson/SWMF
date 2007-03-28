#!MC 1000

### set useful constants
$!Varset |PI| = (2.*asin(1.))
$!Varset |d2r| = (|PI|/180.)
$!Varset |r2d| = (180./|PI|)

### XY frame
$!CREATENEWFRAME 
  XYPOS
    {
    X = 1.
    Y = 1.
    }
  WIDTH = 1.
  HEIGHT = 1.
$!READSTYLESHEET  "styleXY.sty" 
  INCLUDEPLOTSTYLE = YES
  INCLUDETEXT = YES
  INCLUDEGEOM = YES
  INCLUDEAUXDATA = YES
  INCLUDESTREAMPOSITIONS = YES
  INCLUDECONTOURLEVELS = YES
  MERGE = NO
  INCLUDEFRAMESIZEANDPOSITION = YES
$!FRAMECONTROL PUSHTOP

### XZ frame
$!CREATENEWFRAME 
  XYPOS
    {
    X = 1.
    Y = 1.
    }
  WIDTH = 1.
  HEIGHT = 1.
$!READSTYLESHEET  "styleXZ.sty" 
  INCLUDEPLOTSTYLE = YES
  INCLUDETEXT = YES
  INCLUDEGEOM = YES
  INCLUDEAUXDATA = YES
  INCLUDESTREAMPOSITIONS = YES
  INCLUDECONTOURLEVELS = YES
  MERGE = NO
  INCLUDEFRAMESIZEANDPOSITION = YES
$!FRAMECONTROL PUSHTOP

### apply style
$!READSTYLESHEET  "style.sty" 
  INCLUDEPLOTSTYLE = YES
  INCLUDETEXT = YES
  INCLUDEGEOM = YES
  INCLUDEAUXDATA = YES
  INCLUDESTREAMPOSITIONS = YES
  INCLUDECONTOURLEVELS = YES
  MERGE = NO
  INCLUDEFRAMESIZEANDPOSITION = YES

### x axis variable
$!LINEMAP [1]  ASSIGN{XAXISVAR = REPLACEXVAR}
$!VIEW AXISNICEFIT
  AXIS = 'X' 
  AXISNUM = 1

### y axis variable
$!LINEMAP [1]  ASSIGN{YAXISVAR = REPLACEYVAR}
$!VIEW AXISNICEFIT
  AXIS = 'Y' 
  AXISNUM = 1

### set range (X axis)
REPLACEISXAXISCUSTOM$!XYLINEAXIS XDETAIL 1 {RANGEMIN = REPLACEXAXISMIN}
REPLACEISXAXISCUSTOM$!XYLINEAXIS XDETAIL 1 {RANGEMAX = REPLACEXAXISMAX}

### set range (Y axis)
REPLACEISYAXISCUSTOM$!XYLINEAXIS YDETAIL 1 {RANGEMIN = REPLACEYAXISMIN}
REPLACEISYAXISCUSTOM$!XYLINEAXIS YDETAIL 1 {RANGEMAX = REPLACEYAXISMAX}

REPLACEISTEXT$!ATTACHTEXT 
REPLACEISTEXT  XYPOS
REPLACEISTEXT    {
REPLACEISTEXT    X = 20.
REPLACEISTEXT    Y = 4.
REPLACEISTEXT    }
REPLACEISTEXT  TEXTSHAPE
REPLACEISTEXT    {
REPLACEISTEXT    HEIGHT = 24
REPLACEISTEXT    }
REPLACEISTEXT  ATTACHTOZONE = NO
REPLACEISTEXT  ANCHOR = LEFT
REPLACEISTEXT  TEXT = 'REPLACETEXT'

### save file
$!PAPER ORIENTPORTRAIT = YES
$!PRINTSETUP PALETTE = COLOR
$!PRINTSETUP SENDPRINTTOFILE = YES
$!PRINTSETUP PRINTFNAME = 'print.cps'
$!PRINT 
