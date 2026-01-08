for i in space-struts/*.mov
  do
    j=`basename $i .mov`
    echo $i,$j
    ffmpeg -i $i -vf scale=400:900 space-struts/$j.mpeg
  done

