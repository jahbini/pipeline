(
cd space-struts
mkdir -p  size400
mkdir -p  size100

for i in *.jpeg
  do
    j=`basename $i .jpeg`
    gm convert $i -resize 400x  size400/$i
    gm convert $i -resize 100x  size100/$i
  done
  )

