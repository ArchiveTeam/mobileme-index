require "rubygems"
require "rest_client"
require "nokogiri"

require "tar_index"

def locate_file(item, file)
  response = RestClient.get("http://archive.org/services/find_file.php?loconly=1&file=#{ item }")
  location_el = Nokogiri::XML(response.body).at_xpath("/results/location")
  "http://#{ location_el["host"] }#{ location_el["dir"] }/#{ file }"
end

def update_item(item_name)
  print "Updating #{ item_name }... "

  response = RestClient.get("http://archive.org/download/#{ item_name }/#{ item_name }_files.xml")
  xml = Nokogiri::XML(response.body)

  files = []
  xml.xpath("/files/file").each do |file_el|
    if file_el["name"]=~/\.tar$/
      files << { :item_name=>item_name,
                 :name=>file_el["name"],
                 :size=>file_el.at_xpath("size").text.to_i }
    end
  end

  files = files.sort_by { |file| file[:name] }

  File.open("items/#{ item_name }.txt", "w") do |f|
    files.each do |file|
      f.puts [ item_name, file[:name], file[:size] ].join("\t")
    end
  end

  puts "#{ files.size } file#{ files.size==1 ? "" : "s" }."

  files
end

def update_file(item_name, file_name)
  print "- Updating #{ item_name }/#{ file_name }..."

  response = RestClient.get("http://archive.org/download/#{ item_name }/#{ file_name }/")
  html = Nokogiri::HTML(response.body)

  files = []
  html.xpath("//pre/a").each do |a_el|
    if a_el.text=~/((public\.me\.com|web\.me\.com|gallery\.me\.com|homepage\.mac\.com)-([^\/]+)\.warc\.gz)$/
      files << { :file=>$1,
                 :domain=>$2,
                 :user=>$3,
                 :datetime=>a_el.next_sibling.text[/^\s+([-0-9]+\s+[:0-9]+)\s([0-9]+)/, 1],
                 :size=>a_el.next_sibling.text[/^\s+\S+\s+\S+\s([0-9]+)/, 1].to_i }
    end
  end

  if files.size == 0
    puts " no files."
    print "  tarview returned an empty result. Indexing tar file..."

    url = locate_file(item_name, file_name)
    ti = TarIndex.new(url)
    prev_progress = nil
    ti.each do |tar_header|
      if tar_header.name=~/((public\.me\.com|web\.me\.com|gallery\.me\.com|homepage\.mac\.com)-([^\/]+)\.warc\.gz)$/
        progress = ((100 * ti.bytes_read) / ti.full_size)
        if progress != prev_progress
          print " #{ progress }%"
          prev_progress = progress
        end
        files << { :file=>$1,
                   :domain=>$2,
                   :user=>$3,
                   :datetime=>Time.at(tar_header.mtime).utc.strftime("%Y-%m-%d %H:%M:%S"),
                   :size=>tar_header.size }
      end
    end
  end

  if files.size > 0
    FileUtils.mkdir_p("files/#{ item_name }")
    File.open("files/#{ item_name }/#{ file_name }.txt", "w") do |f|
      files.sort_by { |file| [ file[:user], file[:domain] ] }.each do |file|
        f.puts [ file[:user], file[:domain], file[:datetime],
                 item_name, file_name, file[:file], file[:size] ].join("\t")
      end
    end
  end

  puts " #{ files.size } file#{ files.size==1 ? "" : "s" }."

  files
end

def update_files(files)
  files.each do |file|
    if not File.exists?("files/#{ file[:item_name] }/#{ file[:name] }.txt")
      begin
        update_file(file[:item_name], file[:name])
      rescue RestClient::RequestTimeout
        puts $!
      rescue RestClient::ResourceNotFound
        puts " Not Found."
      end
    end
  end
end

def update_items_txt(items)
  puts "Updating items.txt."
  File.open("items.txt", "w") do |f|
    items.to_a.sort_by do |item_name, updatedate|
      item_name
    end.each do |item_name, updatedate|
      f.puts [ item_name, updatedate ].join("\t")
    end
  end
end


$stdout.sync = true


# load previous data
print "Loading previous item list... "
prev_items = []
if File.exists?("items.txt")
  File.readlines("items.txt").each do |line|
    line.strip!
    if line.strip=~/^(\S+)\t([-T:Z0-9]+)/
      # item_name, updatedate
      prev_items << [ $1, $2 ]
    end
  end
end
puts "#{ prev_items.size } items."

items = Hash[prev_items]


# download items
print "Downloading current item list... "

response = RestClient.get("http://archive.org/advancedsearch.php?q=collection%3Aarchiveteam-mobileme%20OR%20identifier%3Aarchiveteam-mobileme-%2A&fl%5B%5D=identifier&fl%5B%5D=oai_updatedate&rows=100000&page=1&output=xml")
items_xml = Nokogiri::XML(response)
latest_items = items_xml.xpath("//doc/str[@name='identifier']").map do |el|
  updatedates = el.xpath("../arr[@name='oai_updatedate']/date").map{|e|e.text}
  { :item_name=>el.text,
    :updatedate=>updatedates.max }
end.sort_by do |item|
  item[:item_name]
end

puts "#{ latest_items.size } items."

changed_items = latest_items.select do |item|
  item[:updatedate] != items[item[:item_name]] or not File.exists?("items/#{ item[:item_name] }.txt")
end

puts "Changed since last run: #{ changed_items.size }."


# update items
changed_items.each_with_index.each do |item, idx|
  puts
  puts "Item #{ idx+1 }/#{ changed_items.size }:"

  begin
    files = update_item(item[:item_name])

    # update files
    update_files(files)

    # update updatedate
    items[item[:item_name]] = item[:updatedate]
    update_items_txt(items)
  rescue
    puts $!
  end
end


puts
puts "Checking for missing files in existing items."

latest_items.each_with_index do |item, idx|
  if File.exists?("items/#{ item[:item_name] }.txt")
    files = File.readlines("items/#{ item[:item_name] }.txt").map do |line|
      line.split("\t")[1]
    end.compact.map do |filename|
      { :item_name=>item[:item_name], :name=>filename }
    end

    # update files
    update_files(files) rescue puts $!
  end
end

