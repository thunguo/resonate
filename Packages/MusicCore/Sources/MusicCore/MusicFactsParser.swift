import Foundation

public enum MusicFactsParser {
    public static func wikiInfo(_ json: JSONValue) -> [String] {
        var facts: [String] = []
        for block in json["data"]["blocks"].array where block["bizCode"].string == "songDetailNewSongWiki" {
            for item in block["rnData"]["blocks"].array {
                let info = item["blockInfo"]
                if item["blockCode"].string == "wikiSubBlockSongInfoVo", !info["desc"].string.isEmpty {
                    facts.append(String(info["desc"].string.prefix(4000)))
                } else if item["blockCode"].string == "wikiSubBlockBaseInfoVo" {
                    for field in info["wikiSubElementVos"].array where ["曲风", "语种", "发行时间", "发行版本", "作词", "作曲", "编曲", "制作人"].contains(field["title"].string) {
                        let values = ([field["content"].string] + field["wikiSubMetaVos"].array.map { $0["text"].string }).filter { !$0.isEmpty }
                        if !values.isEmpty { facts.append(field["title"].string + "：" + values.joined(separator: "、")) }
                    }
                }
            }
        }
        return facts
    }
    public static func wikiSummary(_ json: JSONValue) -> [String] {
        let allowed = Set(["作词", "作曲", "编曲", "制作人", "制作", "演唱", "发行时间", "发行日期", "发行公司", "语种", "曲风"])
        var facts: [String] = []
        for block in json["data"]["blocks"].array where block["code"].string == "SONG_PLAY_ABOUT_SONG_BASIC" {
            for creative in block["creatives"].array {
                let title = creative["uiElement"]["mainTitle"]["title"].string
                guard allowed.contains(title) else { continue }
                var values = creative["uiElement"]["textLinks"].array.map { $0["text"].string }
                values += creative["resources"].array.filter { $0["valid"].isNull || $0["valid"].bool }.map { $0["uiElement"]["mainTitle"]["title"].string }
                var seen = Set<String>(); values = values.filter { !$0.isEmpty && seen.insert($0).inserted }
                if !values.isEmpty { facts.append(title + "：" + values.joined(separator: "、")) }
            }
        }
        return facts
    }
}
