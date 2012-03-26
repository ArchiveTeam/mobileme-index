require "rubygems"
require "rest_client"
require "nokogiri"

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

  files.sort_by { |file| file[:name] }

  File.open("items/#{ item_name }.txt", "w") do |f|
    files.each do |file|
      f.puts [ item_name, file[:name], file[:size] ].join("\t")
    end
  end

  puts "#{ files.size } file#{ files.size==1 ? "" : "s" }."

  files
end

def update_file(item_name, file_name)
  print "- Updating #{ item_name }/#{ file_name }... "

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

  FileUtils.mkdir_p("files/#{ item_name }")
  File.open("files/#{ item_name }/#{ file_name }.txt", "w") do |f|
    files.sort_by { |file| [ file[:user], file[:domain] ] }.each do |file|
      f.puts [ file[:user], file[:domain], file[:datetime],
               item_name, file_name, file[:file], file[:size] ].join("\t")
    end
  end

  puts "#{ files.size } file#{ files.size==1 ? "" : "s" }."

  files
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

response = RestClient.get("http://archive.org/advancedsearch.php?q=collection%3Aarchiveteam-mobileme&fl%5B%5D=identifier&fl%5B%5D=oai_updatedate&rows=100000&page=1&output=xml")
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

  files = update_item(item[:item_name])

  # update files
  files.each do |file|
    if not File.exists?("files/#{ file[:item_name] }/#{ file[:name] }.txt")
      update_file(file[:item_name], file[:name])
    end
  end

  # update updatedate
  items[item[:item_name]] = item[:updatedate]
  update_items_txt(items)
end



