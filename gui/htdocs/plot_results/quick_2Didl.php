<?php
  $runidlexists = "0";
  $dirTMP = opendir($imagedir);
  while( $file = readdir( $dirTMP ) ) {
    if (eregi("runidl.sh", $file)) {
      $runidlexists = "1";
    }
  }
  if(! $runidlexists) {
    Exec("cd $imagedir;
          echo '#!/bin/sh' > runidl.sh;
          echo '' >> runidl.sh;
          echo 'IDL_PATH=../../../Idl:\${IDL_PATH}' >> runidl.sh;
          echo 'IDL_STARTUP=../../../Idl/idlrc_gui' >> runidl.sh;
          echo 'export IDL_PATH IDL_STARTUP' >> runidl.sh;
          echo '' >> runidl.sh;
          echo 'idl batch$macroextension' >> runidl.sh;
          chmod 755 runidl.sh");
  }
  $cwd = getcwd();
  Exec("rsync -av $imagedir/runidl.sh $batchdir/$tmpdir/;
        rsync -av $imagedir/batch-${number}.pro $batchdir/$tmpdir/batch.pro;
        cd $batchdir/$tmpdir;
        ln -s $cwd/$filedir/$plotfile file.out");
  Exec("cd $batchdir/$tmpdir;
        echo '#!/bin/sh' > batchscript.sh;
        echo '' >> batchscript.sh;
        echo './runidl.sh >& batch.log' >> batchscript.sh;
        echo 'cp -f batch.log ../.' >> batchscript.sh;
        echo 'mv *ps $file1' >> batchscript.sh;
        chmod 755 batchscript.sh");
?>
