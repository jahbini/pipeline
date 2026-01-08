fs = require 'fs'
allFiles = fs.readdirSync 'static/images/space-struts'
Files = {}
for file in allFiles
  number = (file.match /.*IMG_(\d\d\d\d)(.*)/)
  continue if !number
  suffix=number[2]
  number=number[1]
  console.log number,file
  Files["#{number}"]={
    heading: 'empty Headline',
    tldr: null,
    photoURL: "/images/space-struts/IMG_" + number + suffix,
    tags: ""
    }

allImages = fs.readFileSync 'src/lib/server/images.json', "utf8"
allImages = JSON.parse allImages
for image in allImages
  number = (file.match /.*IMG_(\d\d\d\d)(.*)/)
  continue if !number
  suffix=number[2]
  number=number[1]
  image.photoURL= "/images/space-struts/IMG_" + number + suffix
  Files["#{number}"]= {...image}


for number,image of Files 
  #number = (image.photoURL.match /.*IMG_(\d\d\d\d).*$/)[1]
  if image.heading == 'empty Headline'
    image.heading = image.photoURL
  image.tldr = image.photoDescription || "A Strut"
  delete image.photoDescription

  console.log "an image", image
  imageText = JSON.stringify(image,null,2);
  templatePage = """
  <script>
  // file for image #{number}
  import Pix from "$lib/Pix.svelte"
   /** @type {import('./$types').PageData} */
   import { page } from "$app/stores";
   import image from "./+page.json";
  </script>
  <div class="container grid">
  <div>
  <Pix { ...image } />
  </div>
<div/><div/>
  </div>
  <style>
  </style>
"""
  fs.mkdirSync "src/routes/pix/#{number}",{recursive:true}
  fs.writeFileSync "src/routes/pix/#{number}/+page.json",imageText unless number == "2544"
  fs.writeFileSync "src/routes/pix/#{number}/+page.svelte",templatePage

