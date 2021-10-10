require 'net/http'
require 'uri'
require 'json'

# This is the endpoint to get all the consumer attacks and related information
# https://api.sibr.dev/eventually/v2/events?sortorder=asc&description=consumer&limit=10000
# - Get all this information
# - Combine related information
# - Get needed info (target name, # of stars lost, item name, wrestling defender)
# - Convert those into the descriptions
# https://alisww.github.io/eventually/#/default/events

# A generic function to query an API and get back a json response
def queryAPI(url)
  uri = URI(url)

  Net::HTTP.start(uri.host, uri.port, :use_ssl => true) do |http|
    request = Net::HTTP::Get.new uri
    response = http.request request
    JSON.parse(response.body)
  end
end

# Pull player information from the blaseball api
def getPlayer(id)
  queryAPI("https://www.blaseball.com/database/players?ids=#{id}")
end


def convert_to_text(events)
  events.map do |event|
    if event[:defender_id]
      if event[:item_defense]
        # A player defended another player with an item: Give the item a rating and print it's name
        ["#{event[:player_name]}", "#{event[:modifiers] + variance}/10", "(Meal prevented by #{event[:defender_name]}'s #{event[:item]})"]
      else
        # Defended by a player, probably one of the detectives. Always rated 0 since nobody likes being piledrived
        ["#{event[:player_name]}", "0.0/10", "(Meal prevented by #{event[:defender_name]})"]
      end
    elsif event[:item] && !event[:item_defense]
      # A player defended themselves with an item: rate the item and print it's name.
      # The more traits an item has, the more delicious it is. Everyone knows this.
      ["#{event[:player_name]}'s #{event[:item]}", "#{event[:modifiers]  + variance}/10", ""]
    elsif event[:after] && event[:before]
      # Chorby Soul and Parker MacMillan are the only players to get perfect 10s
      # Otherwise, rating is a function of how many stars were lost
      rating = event[:player_name] == "Chorby Soul" || event[:player_name] == "Parker MacMillan" ? 10.0 : (event[:after]/event[:before] * 5 + 5).round(1)
      ["#{event[:player_name]}", "#{rating}/10", ""]
    elsif event[:description].start_with?("SALMON")
      # Consumer fired out of Salmon Cannons. Gets a rating of 2ish - being fired out of a cannon is kinda fun
      ["#{event[:player_name]}", "#{2.0 + variance}/10", "(Meal prevented by Salmon Cannons)"]
    else
      p "Failure to classify #{event}"
      ["#{event[:player_name]}'s ????", "0/10"]
    end
  end
end

# Takes all the players that were mentioned in the events and pulls in their information
# Most importantly, their names
def populate_players(events)
  player_ids = events
    .map {|event| [event[:player_id], event[:defender_id]] }
    .flatten
    .uniq
    .compact

  player_names = {}
  player_ids.each_slice(10) do |ids|
    players = getPlayer(ids.join(','))
    players.each do |player|
      player_names[player["id"]] = getName(player)
    end
  end

  # Puts the names back into the events
  events.map do |event|
    event[:player_name] = player_names[event[:player_id]]
    if event[:defender_id]
      event[:defender_name] = player_names[event[:defender_id]]
    end
    event
  end
end

# Extracts a players name. It's slightly more complicated because so many players were scattered by the desert
def getName(player)
  if player["permAttr"].include?("SCATTERED")
    player["state"]["unscatteredName"]
  else
    player["name"]
  end
end

# Sorts events by the name of the targetted player
def player_sort(events)
  events.sort do |a, b|
    if a[:player_name] == b[:player_name]
      (a[:season] * 200 + a[:day]) <=> (b[:season] * 200 + b[:day])
    else
      last_name(a[:player_name]) <=> last_name(b[:player_name])
    end
  end
end

# There are players who share last names, players with only one name (NaN, specifically), and players 
# with more than two words in their name so we process the name here into a format the sorts correctly
def last_name(name)
  pieces = name.split(" ")
  if pieces.length == 1
    name
  else
    first_name = pieces.shift
    "#{pieces.join(" ")} #{first_name}"
  end
end

# Pulls all the shark events from SIBR's eventually api and counts how all the various attacks turned out
def sharkStats
  events = queryAPI("https://api.sibr.dev/eventually/v2/events?sortorder=desc&type=67&limit=10")
  events.reduce({
    success: [],
    chorby: [],
    defended: [],
    cannon: [],
    wrestled: []
  }) do |acc, event|
    season = event["season"]
    desc = event["description"]
    if desc.include?("DEFENDS")
      acc[:defended][season] ||= 0
      acc[:defended][season] += 1
    elsif desc.include?("CHORBY SOUL")
      acc[:chorby][season] ||= 0
      acc[:chorby][season] += 1
    elsif desc.include?("A CONSUMER")
      acc[:wrestled][season] ||= 0
      acc[:wrestled][season] += 1
    elsif desc.include?("SALMON")
      acc[:cannon][season] ||= 0
      acc[:cannon][season] += 1
    else
      acc[:success][season] ||= 0
      acc[:success][season] += 1
    end
    acc
  end
end

# Gets every event that includes the word "consumer" from SIBR's eventually api
# And transforms them into a format we can use to generate the credits
def sharkAttacks
  attack_events = queryAPI("https://api.sibr.dev/eventually/v2/events?description=consumer&limit=2000")
  processed = attack_events.reduce({}) do |acc, event|
    case event["type"]
    when 67
      # Straightforward consumer attack
      id = event["id"]
      acc[id] ||= {}
      acc[id][:description] = event["description"]
      acc[id][:player_id] = event["playerTags"][0]
      acc[id][:defender_id] = event["description"].start_with?("CONSUMER") ? nil : event["playerTags"][1]
      acc[id][:defender_id] ||= event["description"].include?("STEELED") ? event["playerTags"][1] : nil;
      acc[id][:item_defense] = event["description"].include?("STEELED");
      acc[id][:season] = event["season"]
      acc[id][:day] = event["day"]
    when 118
      # Stat loss
      id = event["metadata"]["parent"]
      acc[id] ||= {}
      acc[id][:before] = event["metadata"]["before"]
      acc[id][:after] = event["metadata"]["after"]
    when 186, 185
      # Item loss/item damage
      id = event["metadata"]["parent"]
      acc[id] ||= {}
      acc[id][:item] = event["metadata"]["itemName"]
      acc[id][:modifiers] = (event["metadata"]["itemName"].split(" ").length - 1).clamp(0, 5)
    when 29
      # This is a coin announcement. She says "consumers" sometimes so I still get it
      # But it's not an attack so we don't use it
    else
      p "Something went wrong"
      p event
      p ""
    end
    acc
  end

  with_players = populate_players(processed.values)

  sorted_players = player_sort(with_players)
  lines = convert_to_text(sorted_players)

  JSON.generate(lines)
end

# Generates a number being .0 and 0.9, which we add to ratings to give them a little bit of difference
# Makes the ratings more interesting to look at
def variance
  Random.rand(0.99).round(1)
end

# Generates all the shark attacks and saves them to a javascript file
# Which the html can load
json = sharkAttacks
File.open("data.js", "w") do |line|
  line.puts("const data = #{json}")
end