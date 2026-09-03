import Foundation
import WingcordCore
import WingcordNet

// MARK: - Slash commands, for `--demo`
//
// **The capture's own bytes, through the real decoder.** Nine commands lifted
// verbatim out of `Slash commands.har`'s 119 KB index and handed to
// `CommandIndex.decode` — so the demo exercises the decoder rather than an
// object graph somebody typed to match it, and the icons it draws are the real
// applications' real assets on the real CDN path.
//
// Between them they cover every shape the composer has to answer for:
//
// | command | what it proves |
// | --- | --- |
// | `wordle` | no options at all — one Return from `/` to sent |
// | `8ball` | one optional string, which the capture nevertheless filled |
// | `avatar` | a `USER` option, which is a snowflake and not a name |
// | `base64` | subcommands, so a leaf is not a command |
// | `meme` | a nine-way `choices` list, four booleans, a `max_length`, and an
// |         | attachment option this client does not offer |
// | `fwkgenre` | choices whose values are **integers**, not strings |

extension DemoFixtures {

    static func populateCommands(_ model: AppModel) {
        guard let data = commandIndexJSON.data(using: .utf8),
              let index = try? CommandIndex.decode(data)
        else { return }

        model.commandIndexes[.account] = index

        // **Dank Memer's own index, for its page in the apps flyout.** Trimmed
        // from 59 commands to the four the screenshots show, chosen for what
        // each proves: `dig` and `hunt` take nothing and draw Send; `work` has
        // five subcommands of which only `apply` takes an option, so one leaf
        // draws a chevron and four draw Send; and `GRIND XP` is the `type: 4`
        // entry point whose own name is the launch button's words.
        if let dankData = dankMemerIndexJSON.data(using: .utf8),
           let dank = try? CommandIndex.decode(dankData)
        {
            model.commandIndexes[.application(ApplicationID(rawValue: 270_904_126_974_590_976))]
                = dank
        }
        // The account's own Frequently Used table, in its own order — the rows
        // the capture's screenshot drew, by the command ids that produced them.
        model.commandFrecency = [
            "991195178100592674",   // esmBot   /count
            "1056124601526128671",  // MiQ      /help
            "991195178230620254",   // esmBot   /ping
            "1331353749247234139",  // Wordle   /wordle
            "991195178020896847",   // esmBot   /avatar
        ]
        model.commandRevision &+= 1
    }

    /// `GET /applications/270904126974590976/application-command-index`,
    /// verbatim from `dank memer.har` (2026-09-03) with 55 commands removed.
    private static let dankMemerIndexJSON = #"""
    {"applications":[{"id":"270904126974590976","name":"Dank Memer","description":"Grind, Fight, Wager, Gamble, Fish, Collect, and more. Do it all, right here.","icon":"a38cf47e5d952bc82bedb9c328725278","bot_id":"270904126974590976","flags":"27705344","embedded_activity_config":{"supported_platforms":["web","ios","android"]}}],"application_commands":[{"id":"1011560371078832204","type":1,"application_id":"270904126974590976","version":"1544333221251129414","name":"dig","description":"Dig in the dirt for bugs and other fun items.","dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":1},{"id":"1011560371171102760","type":1,"application_id":"270904126974590976","version":"1544333221372624949","name":"hunt","description":"Grab a rifle from the shop and go hunting for fun items!","dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":2},{"id":"1011560371267579942","type":1,"application_id":"270904126974590976","version":"1544333221645385799","name":"work","description":"Get a job and work for coins and some random rare items.","options":[{"type":1,"name":"shift","description":"Play a minigame to fulfill your work shift."},{"type":1,"name":"stars","description":"View all work stars you have collected."},{"type":1,"name":"apply","description":"Apply for a job.","options":[{"type":3,"name":"job","description":"The job you want to apply for.","required":true,"autocomplete":true}]},{"type":1,"name":"resign","description":"Resign from a job."},{"type":1,"name":"list","description":"List of available jobs."}],"dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":3},{"id":"1488890364462108734","type":4,"application_id":"270904126974590976","version":"1488890513720606841","name":"GRIND XP","description":"Grind Dank Memer XP","dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"handler":2}],"version":"1544742002233708674"}
    """#

    private static let commandIndexJSON = """
    {"applications":[
      {"id":"429305856241172480","name":"esmBot","description":"",
       "icon":"a20f739886ae47cfb10fa069416e8ed3","bot_id":"429305856241172480","flags":"565248"},
      {"id":"949479338275913799","name":"Make it a Quote","description":"",
       "icon":"3a521f17415177f7fc458d91b28ac400","bot_id":"949479338275913799","flags":"28114944"},
      {"id":"1211781489931452447","name":"Wordle","description":"",
       "icon":"8904fec86de9bb7a71b2ae1e71a1adbc","bot_id":"1211781489931452447","flags":"28114944"},
      {"id":"356268235697553409","name":".fmbot","description":"",
       "icon":"48609542a5d70f721a40fa4c4d3e6ac8","bot_id":"356268235697553409","flags":"565248"}],
     "application_commands":[
      {"id":"1331353749247234139","type":1,"application_id":"1211781489931452447",
       "version":"1354514123479711747","name":"wordle",
       "description":"Play the official Wordle from New York Times Games",
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":1},
      {"id":"1056124601526128671","type":1,"application_id":"949479338275913799",
       "version":"1500779648215416883","name":"help","description":"\\u2753 Show Bot Help",
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":2},
      {"id":"991195178020896847","type":1,"application_id":"429305856241172480",
       "version":"1484223048012923031","name":"avatar","description":"Gets a user's avatar",
       "options":[{"type":6,"name":"member","description":"The member to get the avatar from"},
                  {"type":5,"name":"server","description":"Gets a user's server avatar"}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":3},
      {"id":"991195178020896838","type":1,"application_id":"429305856241172480",
       "version":"1500984029405778108","name":"8ball",
       "description":"Asks the magic 8-ball a question",
       "options":[{"type":3,"name":"question",
                   "description":"A question you want to ask the ball"}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":9},
      {"id":"991195178465513546","type":1,"application_id":"429305856241172480",
       "version":"1484223046679134280","name":"meme",
       "description":"Generates a meme from an image (separate top/bottom text with a comma)",
       "options":[
         {"type":3,"name":"text","description":"The text to put on the image",
          "required":true,"max_length":4096},
         {"type":11,"name":"image","description":"An image/GIF attachment"},
         {"type":3,"name":"link","description":"An image/GIF URL"},
         {"type":5,"name":"togif","description":"Force GIF output"},
         {"type":5,"name":"spoiler","description":"Attempt to send output as a spoiler"},
         {"type":5,"name":"ephemeral",
          "description":"Attempt to send output as an ephemeral/temporary response"},
         {"type":5,"name":"case",
          "description":"Make the meme text case-sensitive (allows for lowercase text)"},
         {"type":3,"name":"font","description":"Specify the font you want to use (default: impact)",
          "choices":[{"name":"futura","value":"futura"},{"name":"impact","value":"impact"},
                     {"name":"helvetica","value":"helvetica"},{"name":"arial","value":"arial"},
                     {"name":"roboto","value":"roboto"},{"name":"noto","value":"noto"},
                     {"name":"times","value":"times"},
                     {"name":"comic sans ms","value":"comic sans ms"},
                     {"name":"ubuntu","value":"ubuntu"}]}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":22},
      {"id":"991195178100592671","type":1,"application_id":"429305856241172480",
       "version":"1484223048012923033","name":"base64",
       "description":"Encodes/decodes a Base64 string",
       "options":[
         {"type":1,"name":"decode","description":"Decodes a Base64 string",
          "options":[{"type":3,"name":"text","description":"The text to decode","required":true}]},
         {"type":1,"name":"encode","description":"Encodes a Base64 string",
          "options":[{"type":3,"name":"text","description":"The text to encode","required":true}]}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":42},
      {"id":"991195178100592674","type":1,"application_id":"429305856241172480",
       "version":"1484223048012923034","name":"count",
       "description":"Gets how many times every command was used",
       "options":[{"type":3,"name":"command",
                   "description":"A specific command to view counts for"}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":72},
      {"id":"991195178230620254","type":1,"application_id":"429305856241172480",
       "version":"1484223048218312717","name":"ping","description":"Pings Discord's servers",
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":59},
      {"id":"1230085982884200552","type":1,"application_id":"356268235697553409",
       "version":"1543944692339581086","name":"fwkgenre",
       "description":"Shows who of your friends listen to a genre",
       "options":[
         {"type":3,"name":"search","description":"The genre or artist you want to view",
          "required":false,"autocomplete":true},
         {"type":4,"name":"mode",
          "description":"The type of response you want - change default with /mode",
          "required":false,"autocomplete":false,
          "choices":[{"name":"Default","value":1},{"name":"Image","value":2},
                     {"name":"Pagination","value":3}]},
         {"type":5,"name":"private","description":"Only show response to you","required":false}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":69}],
     "version":"1544744582213013756"}
    """
}
