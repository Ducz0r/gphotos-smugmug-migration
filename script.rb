#!/usr/bin/env ruby

########################################################
##                                                    ##
## Globals                                            ##
##                                                    ##
########################################################

SRC_FOLDER = '/home/duco/Desktop/blog/2011'
LR_CATALOG = '/home/duco/Desktop/blog/Lightroom catalog-2.lrcat'
LR_ROOT_FOLDER = '2011'
LR_INITIAL_CHANGE_COUNTER = 450816

VALID_EXTENSIONS = ['jpg', 'jpeg', 'png', 'gif']

########################################################
##                                                    ##
## Functions                                          ##
##                                                    ##
########################################################

# Try to install missing gems inside the provided block.
def installing_missing_gems(&_block)
  yield
rescue LoadError => e
  gem_name = e.message.split('--').last.strip
  install_command = 'gem install ' + gem_name

  # Install missing gem
  system(install_command) || exit(1)

  # Retry
  Gem.clear_paths
  require gem_name
  retry
end

def is_int_string?(str)
  /\A\d+\z/.match(str)
end

def get_last_insert_row_id(db, table_name)
  db.execute("SELECT rowid FROM #{table_name} ORDER BY rowid DESC limit 1")[0][0]
end

########################################################
##                                                    ##
## Code                                               ##
##                                                    ##
########################################################

installing_missing_gems do
  require 'sqlite3'
end

begin
  db = SQLite3::Database.new(LR_CATALOG)

  lr_collection_data = []

  # Find root folder
  result = db.execute('SELECT id_local FROM AgLibraryRootFolder WHERE name = ?', [LR_ROOT_FOLDER])
  if result.size == 0
    raise Exception.new('[ERROR] Root folder in LR Catalog not found')
  elsif result.size > 1
    raise Exception.new('[ERROR] Multiple root folders in LR Catalog found')
  end
  lr_root_folder_id = result[0][0]

  # Find original, sub-root folders (date folders)
  lr_subroot_folders = []
  result = db.execute('SELECT id_local, pathFromRoot FROM AgLibraryFolder WHERE rootFolder = ?', [lr_root_folder_id])
  result.each do |row|
    if row[1].count('/') == 1
      row_split = row[1].split(' ')
      if row_split.length < 2 || !is_int_string?(row_split[0])
        raise Exception.new("[ERROR] LR subroot folder has invalid name: #{LR_ROOT_FOLDER}/#{row[1]}")
      end

      date = row_split[0]
      if row_split.length > 2 && is_int_string?(row_split[1])
        date = "#{row_split[0]} #{row_split[1]}"
      end

      lr_subroot_folders << {
        id: row[0],
        name: row[1],
        date: date,
        subfolders: []
      }
    end
  end

  # Now, populate the subfolders of subfolders (if possible)
  lr_subroot_folders.each do |folder|
    result.each do |row|
      next if row[0] == folder[:id]
      if row[1].start_with?(folder[:name])
        folder[:subfolders] << { id: row[0], name: row[1] }
      end
    end
  end

  # Check that all source files/images have valid extensions
  src_folders = Dir.children(SRC_FOLDER)
  src_folders.each do |src_subfolder|
    files = Dir.children("#{SRC_FOLDER}/#{src_subfolder}")
    files.each do |file|
      unless VALID_EXTENSIONS.include?(file.downcase.split('.')[-1])
        raise Exception.new("[ERROR] File has invalid extension: #{SRC_FOLDER}/#{src_subfolder}/#{file}")
      end
    end
  end

  # Iterate through source folders
  src_folders.each do |src_subfolder|
    src_subfolder_split = src_subfolder.split(' ')
    if src_subfolder_split.length < 2 || !is_int_string?(src_subfolder_split[0])
      raise Exception.new("[ERROR] Source folder has invalid name: #{SRC_FOLDER}/#{src_subfolder}")
    end

    src_date = src_subfolder_split[0]
    if src_subfolder_split.length > 2 && is_int_string?(src_subfolder_split[1])
      src_date = "#{src_subfolder_split[0]} #{src_subfolder_split[1]}"
    end

    # Find the matched "subroot" library in LR
    result = lr_subroot_folders.select{|sf| sf[:date] == src_date}
    if result.length == 0
      puts("[WARNING] Cannot find matching LR folder for source folder, skipping: #{SRC_FOLDER}/#{src_subfolder}")
      next
    elsif result.length > 1
      puts("[WARNING] Found multiple LR folders matching source folder, skipping: #{SRC_FOLDER}/#{src_subfolder}")
      next
    end

    lr_subroot_folder = result[0]

    src_images = Dir.children("#{SRC_FOLDER}/#{src_subfolder}")

    # Fetch all image files in LR that belong to the matched library/folder
    lr_files = db.execute('SELECT id_local, baseName FROM AgLibraryFile WHERE folder = ?', lr_subroot_folder[:id])
    lr_subroot_folder[:subfolders].each do |sf|
      db.execute('SELECT id_local, baseName FROM AgLibraryFile WHERE folder = ?', sf[:id]) do |row|
        lr_files << row
      end
    end

    lr_images = []
    src_images.each do |src_image|
      src_image_without_ext = src_image.split('.')[0]
      lr_file = lr_files.select{|i| i[1] == src_image_without_ext}
      if lr_file.length == 0
        puts("[WARNING] Cannot find matching LR library file for source image, skipping: #{SRC_FOLDER}/#{src_subfolder}/#{src_image}")
        next
      elsif lr_file.length > 1
        puts("[WARNING] Found multiple LR library files matching source image, skipping: #{SRC_FOLDER}/#{src_subfolder}/#{src_image}")
        next
      end

      # Map filtered file to image
      result = db.execute('SELECT id_local FROM Adobe_images WHERE rootFile = ?', [lr_file[0][0]])
      if result.length == 0
        puts("[WARNING] Cannot find matching LR image for source image, skipping: #{SRC_FOLDER}/#{src_subfolder}/#{src_image}")
        next
      elsif result.length > 1
        puts("[WARNING] Found multiple LR images matching source image, skipping: #{SRC_FOLDER}/#{src_subfolder}/#{src_image}")
        next
      end

      lr_images << result[0][0]
    end

    # Create the neccesary collection data object for LR
    lr_collection_data << {
      name: src_subfolder,
      image_ids: lr_images
    }
  end

  # Check with user whether to continue
  puts('-----------------------')
  puts('')
  puts('Continue with creating new collections in Lightroom? (y/N)')
  puts('WARNING: This action is irreversible, and could break your Catalog -> backup your LR Catalog before performing this action!')
  STDOUT.flush
  answer = gets.chomp
  unless answer == 'y'
    raise Exception.new('Exiting...')
  end

  # Alright, create the collections in Lightroom!
  cc = LR_INITIAL_CHANGE_COUNTER
  lr_collection_data.each do |lr_collection|
    if lr_collection[:image_ids].length < 1
      puts("[INFO] Skipping collection (0 images): #{lr_collection[:name]}")
      next
    end

    puts("[INFO] Creating collection: #{lr_collection[:name]}")

    db.execute(
      'INSERT INTO AgLibraryCollection (creationId, genealogy, imageCount, name, parent, systemOnly) VALUES (?, ?, ?, ?, ?, ?)',
      [
        'com.adobe.ag.library.collection',
        '',
        nil,
        lr_collection[:name],
        nil,
        '0.0'
      ]
    )
    lr_collection_id = get_last_insert_row_id(db, 'AgLibraryCollection')

    db.execute("UPDATE AgLibraryCollection SET genealogy = '/7#{lr_collection_id}' WHERE id_local = #{lr_collection_id}")

    db.execute(
      'INSERT INTO AgLibraryCollectionChangeCounter (collection, changeCounter) VALUES (?, ?)',
      [lr_collection_id, cc]
    )
    cc += 1

    lr_collection[:image_ids].each do |image_id|
      db.execute(
        'INSERT INTO AgLibraryCollectionImage (collection, image, pick, positionInCollection) VALUES (?, ?, ?, ?)',
        [
          lr_collection_id,
          image_id,
          '0.0',
          nil
        ]
      )
      lr_ci_id = get_last_insert_row_id(db, 'AgLibraryCollectionImage')

      db.execute(
        'INSERT INTO AgLibraryCollectionImageChangeCounter (collectionImage, collection, image, changeCounter) VALUES (?, ?, ?, ?)',
        [lr_ci_id, lr_collection_id, image_id, cc]
      )
      cc += 1
    end

    db.execute(
      'INSERT INTO AgLibraryCollectionCoverImage (collection, collectionImage) VALUES (?, ?)',
      [lr_collection_id, get_last_insert_row_id(db, 'AgLibraryCollectionImage')]
    )
  end
rescue Exception => e
  puts(e.message)
end