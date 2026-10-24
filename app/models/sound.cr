# /play sounds (oracle sound.rb): BUILTIN catalog + find_by_name,
# ported from ChatLayout.
class Sound
  attr_reader name : String
  attr_reader text : String?
  attr_reader image_name : String?
  attr_accessor image_width : Int32 = 0
  attr_accessor image_height : Int32 = 0

  def initialize(@name, @text = nil, @image_name = nil)
  end

  def image? : Bool
    !@image_name.nil?
  end

  BUILTIN = {
    "56k"         => {image: {"56k.webp", 79, 33}},
    "bell"        => {text: "🔔"},
    "bezos"       => {text: "😆💭"},
    "bueller"     => {text: "anyone?"},
    "butts"       => {text: "👐 🚬"},
    "clowntown"   => {image: {"clowntown.webp", 210, 150}},
    "cottoneyejoe" => {text: "🎶🙉🎶 "},
    "crickets"    => {text: "hears crickets chirping"},
    "curb"        => {image: {"curb.webp", 150, 101}},
    "dadgummit"   => {text: "dad gummit!! 🎣"},
    "dangerzone"  => {image: {"dangerzone.webp", 157, 32}},
    "danielsan"   => {text: "🎆 🏆 🎆"},
    "deeper"      => {image: {"top.webp", 188, 80}},
    "ballmer"     => {text: "developers!"},
    "donotwant"   => {image: {"donotwant.webp", 150, 150}},
    "drama"       => {image: {"drama.webp", 300, 16}},
    "flawless"    => {text: "#flawless"},
    "glados"      => {text: "🤖💢"},
    "gogogo"      => {text: "Go, go, go!"},
    "greatjob"    => {image: {"greatjob.webp", 79, 16}},
    "greyjoy"     => {text: "😖🎺"},
    "guarantee"   => {text: "guarantees it 👌"},
    "heygirl"     => {text: "✨💁✨"},
    "honk"        => {text: "HONK"},
    "horn"        => {text: "🐶 ✂️ 🐱"},
    "horror"      => {text: "💀 💀 💀 💀 💀 💀 💀"},
    "inconceivable" => {text: "doesn't think it means what you think it means…"},
    "letitgo"     => {text: "❄️👩❄️⛄️❄️"},
    "live"        => {text: "is DOING IT LIVE"},
    "loggins"     => {image: {"loggins.webp", 200, 151}},
    "makeitso"    => {text: "make it so 👉"},
    "noooo"       => {text: "👸💀😒"},
    "nyan"        => {image: {"nyan.webp", 36, 15}},
    "ohmy"        => {text: "raises an eyebrow 😏"},
    "ohyeah"      => {text: "isn't playing by the rules"},
    "pushit"      => {image: {"pushit.webp", 104, 15}},
    "rimshot"     => {text: "plays a rimshot"},
    "rollout"     => {text: "is rolling out 🚗"},
    "rumble"      => {image: {"rumble.webp", 220, 150}},
    "sax"         => {text: "🌇🎷🎶"},
    "secret"      => {text: "found a secret area 🔑"},
    "sexyback"    => {text: "🔞"},
    "story"       => {text: "and now you know…"},
    "tada"        => {text: "plays a fanfare 🎏"},
    "tmyk"        => {text: "✨ ⭐️ The More You Know ✨ ⭐️"},
    "totes"       => {text: "😁👍"},
    "trololo"     => {text: "трололо"},
    "trombone"    => {text: "plays a sad trombone"},
    "unix"        => {text: "knows this 💻"},
    "vuvuzela"    => {text: "======<() ~ ♪ ~♫"},
    "what"        => {image: {"what.webp", 100, 131}},
    "whoomp"      => {text: "👏‼️😎"},
    "wups"        => {text: "wups!"},
    "yay"         => {image: {"yay.webp", 103, 50}},
    "yeah"        => {image: {"yeah.webp", 104, 15}},
    "yodel"       => {text: "📣🗻🙉"},
  }

  def self.find_by_name(name : String) : Sound?
    spec = BUILTIN[name]? || return nil
    sound = Sound.new(name, text: spec[:text]? || nil,
      image_name: spec[:image]?.try(&.[0]))
    if (image = spec[:image]?)
      sound.image_width = image[1]
      sound.image_height = image[2]
    end
    sound
  end
end
