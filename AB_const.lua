-- AB_const.lua
-- The constants

AB_const = {}
AB_const.VERSION = "0.9.83"

AB_const.DEFAULT_PREFIX_TEXT = "AutoBand"
AB_const.MAX_PREFIX_LENGTH = 20
AB_const.DEFAULT_PREFIX_COLOR_NAME = "cyan"
AB_const.DEFAULT_LEAD_COLOR_NAME = "red"
AB_const.DEFAULT_PREFIX_USE_GUILD = false
AB_const.TOOFAR_RADIUS_SETTING_DEFAULT = "default"
AB_const.TOOFAR_RADIUS_SETTING_LONG    = "long"
AB_const.TOOFAR_RADIUS_SETTING_FAR     = "far"
AB_const.TOOFAR_RADIUS_SETTING_MAX     = "max"

AB_const.TOOFAR_DISTANCE_VALUES = {
    [AB_const.TOOFAR_RADIUS_SETTING_DEFAULT] = 150,
    [AB_const.TOOFAR_RADIUS_SETTING_LONG]    = 300,
    [AB_const.TOOFAR_RADIUS_SETTING_FAR]     = 450,
    [AB_const.TOOFAR_RADIUS_SETTING_MAX]     = 600
}
AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING = AB_const.TOOFAR_RADIUS_SETTING_DEFAULT
AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD = 500

-- Complete AB_const color palette
-- Primary and neutral colors
AB_const.COLOR_WHITE     = { 255, 255, 255 }
AB_const.COLOR_GRAY      = { 128, 128, 128 }
AB_const.COLOR_SILVER    = { 192, 192, 192 }
-- Legacy palette
AB_const.COLOR_CYAN        = { 0, 255, 255 }
AB_const.COLOR_GREEN       = { 0, 255, 0 }
AB_const.COLOR_MAGENTA     = { 255, 0, 255 }
AB_const.COLOR_RED         = { 255, 0, 0 }
AB_const.COLOR_YELLOW      = { 255, 255, 0 }
AB_const.COLOR_ORANGE      = { 255, 128, 0 }
AB_const.COLOR_LIME        = { 128, 255, 0 }
AB_const.COLOR_TEAL        = { 0, 128, 128 }
AB_const.COLOR_PINK        = { 255, 192, 203 }
AB_const.COLOR_BROWN       = { 150, 75, 0 }
AB_const.COLOR_LIGHT_BROWN = { 202, 165, 127 }
AB_const.COLOR_TAN         = { 210, 180, 140 }
-- Other browns
AB_const.COLOR_PERU        = { 205, 133,  63 }
AB_const.COLOR_BURLYWOOD   = { 222, 184, 135 }
AB_const.COLOR_WHEAT       = { 245, 222, 179 }
-- Premium / accent hues
AB_const.COLOR_GOLD      = { 255, 215, 0 }
AB_const.COLOR_GOLDENROD = { 218, 165, 32 }
AB_const.COLOR_CRIMSON   = { 220, 20, 60 }
AB_const.COLOR_SALMON    = { 250, 128, 114 }
-- Soft pastels
AB_const.COLOR_SKY       = { 135, 206, 235 }
AB_const.COLOR_TURQUOISE = { 64, 224, 208 }
AB_const.COLOR_MINT      = { 189, 252, 201 }
-- Internal display colors. These are intentionally not user-selectable in AVAILABLE_COLORS.
AB_const.COLOR_DARK_BLUE  = { 70, 120, 205 }
AB_const.COLOR_DARK_GOLD  = { 196, 142, 35 }
AB_const.COLOR_DARK_GREEN = { 50, 170, 75 }
AB_const.COLOR_PURPLE     = { 175, 95, 235 }

AB_const.AVAILABLE_COLORS = {
    ["brown"]      = AB_const.COLOR_BROWN,
    ["burlywood"]  = AB_const.COLOR_BURLYWOOD,
    ["cyan"]       = AB_const.COLOR_CYAN,
    ["crimson"]    = AB_const.COLOR_CRIMSON,
    ["gold"]       = AB_const.COLOR_GOLD,
    ["goldenrod"]  = AB_const.COLOR_GOLDENROD,
    ["gray"]       = AB_const.COLOR_GRAY,
    ["green"]      = AB_const.COLOR_GREEN,
    ["lime"]       = AB_const.COLOR_LIME,
    ["lightbrown"] = AB_const.COLOR_LIGHT_BROWN,
    ["magenta"]    = AB_const.COLOR_MAGENTA,
    ["mint"]       = AB_const.COLOR_MINT,
    ["orange"]     = AB_const.COLOR_ORANGE,
    ["peru"]       = AB_const.COLOR_PERU,
    ["pink"]       = AB_const.COLOR_PINK,
    ["red"]        = AB_const.COLOR_RED,
    ["salmon"]     = AB_const.COLOR_SALMON,
    ["silver"]     = AB_const.COLOR_SILVER,
    ["sky"]        = AB_const.COLOR_SKY,
    ["tan"]        = AB_const.COLOR_TAN,
    ["teal"]       = AB_const.COLOR_TEAL,
    ["turquoise"]  = AB_const.COLOR_TURQUOISE,
    ["wheat"]      = AB_const.COLOR_WHEAT,
    ["white"]      = AB_const.COLOR_WHITE,
    ["yellow"]     = AB_const.COLOR_YELLOW,
}
AB_const.AVAILABLE_COLOR_NAMES_SORTED = nil

AB_const.GROUP_SIZE = 6
AB_const.MAX_WB_GROUPS = 4
AB_const.HEARTBEAT = 5
AB_const.KICK_PERIOD = 5
AB_const.DEFAULT_CMD_TICKS = 1
-- Longest queued chat command (e.g. "/wb <prefix markup> text") a too-far warning line
-- may be before it splits. Live 2026-10-30: /wb lines of 499 characters arrive intact;
-- 450 keeps a margin below that.
AB_const.CHAT_LINE_MAX_LEN = 450
AB_const.AUTOKICK = false
AB_const.AUTOKICKTOOFAR = false
AB_const.AUTOKICK_WE_WH = false
AB_const.AUTOKICKRVRZONE = true
AB_const.AUTOKICK_IGNORELIST = false
AB_const.GUILDPRIORITY = false
AB_const.ALTCHECK = true
AB_const.EXCLUDE_REALM_HEALER_ALT_SPEC = true
AB_const.PRINTROLE = true
AB_const.PRINT_ARRIVAL_NOTIFY_TAGS = false
AB_const.AUTOFORM_SEARCH = false
AB_const.SEARCH_DISCORD_REQ = false
AB_const.SEARCH_NO_MIC = false
AB_const.AUTONOTE = false
AB_const.AUTOPARTYNOTE = true
AB_const.KICKLOWRNK = false
AB_const.DEFAULT_MAX_TANKS = 8
AB_const.DEFAULT_MAX_HEALERS = 8
AB_const.DEFAULT_MAX_DPS = 8
AB_const.DPS_WEIGHTING_ENABLED = false
AB_const.DEFAULT_MAX_MDPS = 4
AB_const.DEFAULT_MAX_RDPS = 4
AB_const.BW_SORC_AS_MDPS = false
AB_const.RESTRICT_RACE = false
AB_const.USE_COMMON_RACE_NAMES = false
AB_const.BACKFILL = true
AB_const.BACKFILL_NO_HEADS_UPS = false
AB_const.SOCIAL_PRIORITY_MODE_OFF = "off"
AB_const.SOCIAL_PRIORITY_MODE_PREFER = "prefer"
AB_const.SOCIAL_PRIORITY_MODE_PROTECT = "protect"
AB_const.SOCIAL_PRIORITY_MODE_PROMOTE = "promote"
AB_const.SOCIAL_PRIORITY_MODES = {
    AB_const.SOCIAL_PRIORITY_MODE_OFF,
    AB_const.SOCIAL_PRIORITY_MODE_PREFER,
    AB_const.SOCIAL_PRIORITY_MODE_PROTECT,
    AB_const.SOCIAL_PRIORITY_MODE_PROMOTE
}
AB_const.DEFAULT_GUILD_PRIORITY_MODE = AB_const.SOCIAL_PRIORITY_MODE_OFF
AB_const.DEFAULT_FRIEND_PRIORITY_MODE = AB_const.SOCIAL_PRIORITY_MODE_OFF
AB_const.GUILD_GROUPING_ENABLED = false

AB_const.EMPTY_TEMPLATE = "<Automatic>" -- name of the automatic template
AB_const.EMPTY_WB_TEMPLATE = { [1] = {}, [2] = {}, [3] = {}, [4] = {} }

AB_const.MINIMUM_RANK = 16
AB_const.MINIMUM_RANK_TANK = AB_const.MINIMUM_RANK
AB_const.MINIMUM_RANK_HEALER = 16
AB_const.MINIMUM_RANK_DPS = AB_const.MINIMUM_RANK
AB_const.MAXIMUM_RANK = 70
AB_const.RANK_REQUIREMENT_CHANGE_GRACE_SECONDS = 10
AB_const.ABBREVATIONS = { ["LEADER"] = "L", ["ASSISTANT"] = "A" }

AB_const.HEALER = "healer"
AB_const.TANK = "tank"
AB_const.MDPS = "mdps"
AB_const.RDPS = "rdps"

-- Define Factions
AB_const.ORDER = "Order"
AB_const.DESTRUCTION = "Destruction"

-- Define Races
AB_const.DWARFS = "Dawi"
AB_const.EMPIRE = "Empire"
AB_const.HIGHELVES = "Asur"
AB_const.CHAOS = "Chaos"
AB_const.DARKELVES = "Druchii"
AB_const.GREENSKINS = "Greenskins"

-- Race Themes
AB_const.RACE_THEMES = {
    [AB_const.DWARFS] = { title = "Dawi", common_title = "Dwarf", prefix = "For the Karaz Ankor! Dawi only ", common_prefix = "For the Karaz Ankor! Dwarf only " },
    [AB_const.EMPIRE] = { title = "Empire", prefix = "For Sigmar! Empire only " },
    [AB_const.HIGHELVES] = { title = "Asur", common_title = "High Elf", prefix = "For the Phoenix King! Asur only ", common_prefix = "For the Phoenix King! High Elf only " },
    [AB_const.CHAOS] = { title = "Chaos", prefix = "Blood for the Blood God! Chaos only " },
    [AB_const.DARKELVES] = { title = "Druchii", common_title = "Dark Elf", prefix = "For Naggaroth! Druchii only ", common_prefix = "For Naggaroth! Dark Elf only " },
    [AB_const.GREENSKINS] = { title = "Greenskin", prefix = "WAAAGH! Greenskins only " },
    ["Default"] = { title = "Mixed", prefix = "" }
}

local function should_use_common_race_names()
    return AutoBand and AutoBand.saved and AutoBand.saved.use_common_race_names == true
end

local function get_race_theme_entry(race)
    return AB_const.RACE_THEMES[race] or AB_const.RACE_THEMES["Default"] or {}
end

function AB_const.GetRaceLoreTitle(race)
    local theme = get_race_theme_entry(race)
    if theme.title and theme.title ~= "" then
        return theme.title
    end
    return race
end

function AB_const.GetRaceCommonTitle(race)
    local theme = get_race_theme_entry(race)
    if theme.common_title and theme.common_title ~= "" then
        return theme.common_title
    end
    return nil
end

function AB_const.RaceSupportsCommonNames(race)
    local lore_title = AB_const.GetRaceLoreTitle(race)
    local common_title = AB_const.GetRaceCommonTitle(race)
    return common_title ~= nil and common_title ~= "" and common_title ~= lore_title
end

function AB_const.GetRaceThemeTitle(race)
    local common_title = AB_const.GetRaceCommonTitle(race)
    if should_use_common_race_names() and common_title and common_title ~= "" then
        return common_title
    end
    return AB_const.GetRaceLoreTitle(race)
end

function AB_const.GetRaceThemePrefix(race)
    local theme = get_race_theme_entry(race)
    if should_use_common_race_names() and theme.common_prefix and theme.common_prefix ~= "" then
        return theme.common_prefix
    end
    return theme.prefix or ""
end

AB_const.WARBAND_PURPOSES = {
    ["ch22"] = { display = "Chap22", description = "Chapter22 public events" },
    ["city"] = { display = "City Siege", description = "Running city siege" },
    ["defending"] = { display = "Defending", description = "Defending keeps/BOs" },
    ["event"] = { display = "EventBoss", description = "Killing EventBoss" },
    ["fort"] = { display = "Fortress", description = "Fortress battle" },
    ["lotd"] = { display = "LotD", description = "Land of the Dead event" },
    ["overflow"] = { display = "Overflow", description = "Supporting other WBs" },
    ["ranking"] = { display = "Ranking keep", description = "Ranking up keep" },
    ["relic"] = { display = "Relic", description = "Sigmartag Relic" },
    ["roaming"] = { display = "Roaming", description = "Open RvR roaming" },
    ["sieging"] = { display = "Sieging", description = "Attacking keeps/BOs" },
}

AB_const.PURPOSE_ALIASES = {
    -- Chapter22
    ["ch22"] = "ch22",
    ["chap22"] = "ch22",
    ["chapter22"] = "ch22",
    ["c22"] = "ch22",
    -- City Siege
    ["city"] = "city",
    ["citysiege"] = "city",
    -- Defending
    ["defending"] = "defending",
    ["defend"] = "defending",
    ["defence"] = "defending",
    ["defense"] = "defending",
    ["def"] = "defending",
    -- Event
    ["event"] = "event",
    ["eventboss"] = "event",
    -- Fort
    ["fort"] = "fort",
    ["fortress"] = "fort",
    -- Land of the Dead
    ["lotd"] = "lotd",
    ["land"] = "lotd",
    ["dead"] = "lotd",
    -- overflow
    ["overflow"] = "overflow",
    ["over"] = "overflow",
    ["of"] = "overflow",
    -- Ranking
    ["ranking"] = "ranking",
    ["boxing"] = "ranking",
    ["boxes"] = "ranking",
    ["box"] = "ranking",
    ["boxrunning"] = "ranking",
    ["supplies"] = "ranking",
    ["supply"] = "ranking",
    ["supplyrunning"] = "ranking",
    ["running"] = "ranking",
    -- Relic (Sigmartag)
    ["relic"] = "relic",
    ["relicrun"] = "relic",
    ["relicdef"] = "relic",
    -- Roaming
    ["roaming"] = "roaming",
    ["roam"] = "roaming",
    ["kill"] = "roaming",
    ["kills"] = "roaming",
    ["killing"] = "roaming",
    -- Sieging
    ["sieging"] = "sieging",
    ["siegeing"] = "sieging",
    ["siege"] = "sieging",
    ["attack"] = "sieging",
    ["attacking"] = "sieging",
    ["ram"] = "sieging",
    ["ramming"] = "sieging",
}

function AB_const.GetPurposeNames()
    local names = {}
    for key, _ in pairs(AB_const.WARBAND_PURPOSES) do
        table.insert(names, key)
    end
    table.sort(names)
    return table.concat(names, "|")
end

AB_const.HEADER_MARGIN = "==="

AB_const.CAREERLINE_MAP = {
    [GameData.CareerLine.ENGINEER]        = AB_const.RDPS,
    [GameData.CareerLine.BRIGHT_WIZARD]   = AB_const.RDPS,
    [GameData.CareerLine.SORCERER]        = AB_const.RDPS,
    [GameData.CareerLine.SQUIG_HERDER]    = AB_const.RDPS,
    [GameData.CareerLine.MAGUS]           = AB_const.RDPS,
    [GameData.CareerLine.SHADOW_WARRIOR]  = AB_const.RDPS,

    [GameData.CareerLine.WITCH_ELF]       = AB_const.MDPS,
    [GameData.CareerLine.WHITE_LION]      = AB_const.MDPS,
    [GameData.CareerLine.SLAYER]          = AB_const.MDPS,
    [GameData.CareerLine.WITCH_HUNTER]    = AB_const.MDPS,
    [GameData.CareerLine.CHOPPA]          = AB_const.MDPS,
    [GameData.CareerLine.MARAUDER]        = AB_const.MDPS,

    [GameData.CareerLine.IRON_BREAKER]    = AB_const.TANK,
    [GameData.CareerLine.CHOSEN]          = AB_const.TANK,
    [GameData.CareerLine.BLACK_ORC]       = AB_const.TANK,
    [GameData.CareerLine.KNIGHT]          = AB_const.TANK,
    [GameData.CareerLine.SWORDMASTER]     = AB_const.TANK,
    [GameData.CareerLine.BLACKGUARD]      = AB_const.TANK,

    [GameData.CareerLine.ZEALOT]          = AB_const.HEALER,
    [GameData.CareerLine.WARRIOR_PRIEST]  = AB_const.HEALER,
    [GameData.CareerLine.RUNE_PRIEST]     = AB_const.HEALER,
    [GameData.CareerLine.ARCHMAGE]        = AB_const.HEALER,
    [GameData.CareerLine.SHAMAN]          = AB_const.HEALER,
    [GameData.CareerLine.DISCIPLE]        = AB_const.HEALER
}

AB_const.CAREERLINE_RACEMAP = {
    [GameData.CareerLine.ENGINEER]        = AB_const.DWARFS,
    [GameData.CareerLine.BRIGHT_WIZARD]   = AB_const.EMPIRE,
    [GameData.CareerLine.SORCERER]        = AB_const.DARKELVES,
    [GameData.CareerLine.SQUIG_HERDER]    = AB_const.GREENSKINS,
    [GameData.CareerLine.MAGUS]           = AB_const.CHAOS,
    [GameData.CareerLine.SHADOW_WARRIOR]  = AB_const.HIGHELVES,

    [GameData.CareerLine.WITCH_ELF]       = AB_const.DARKELVES,
    [GameData.CareerLine.WHITE_LION]      = AB_const.HIGHELVES,
    [GameData.CareerLine.SLAYER]          = AB_const.DWARFS,
    [GameData.CareerLine.WITCH_HUNTER]    = AB_const.EMPIRE,
    [GameData.CareerLine.CHOPPA]          = AB_const.GREENSKINS,
    [GameData.CareerLine.MARAUDER]        = AB_const.CHAOS,

    [GameData.CareerLine.IRON_BREAKER]    = AB_const.DWARFS,
    [GameData.CareerLine.CHOSEN]          = AB_const.CHAOS,
    [GameData.CareerLine.BLACK_ORC]       = AB_const.GREENSKINS,
    [GameData.CareerLine.KNIGHT]          = AB_const.EMPIRE,
    [GameData.CareerLine.SWORDMASTER]     = AB_const.HIGHELVES,
    [GameData.CareerLine.BLACKGUARD]      = AB_const.DARKELVES,

    [GameData.CareerLine.ZEALOT]          = AB_const.CHAOS,
    [GameData.CareerLine.WARRIOR_PRIEST]  = AB_const.EMPIRE,
    [GameData.CareerLine.RUNE_PRIEST]     = AB_const.DWARFS,
    [GameData.CareerLine.ARCHMAGE]        = AB_const.HIGHELVES,
    [GameData.CareerLine.SHAMAN]          = AB_const.GREENSKINS,
    [GameData.CareerLine.DISCIPLE]        = AB_const.DARKELVES
}

AB_const.CAREERLINE_FACTIONMAP = {
    [GameData.CareerLine.ENGINEER]        = AB_const.ORDER,
    [GameData.CareerLine.BRIGHT_WIZARD]   = AB_const.ORDER,
    [GameData.CareerLine.SORCERER]        = AB_const.DESTRUCTION,
    [GameData.CareerLine.SQUIG_HERDER]    = AB_const.DESTRUCTION,
    [GameData.CareerLine.MAGUS]           = AB_const.DESTRUCTION,
    [GameData.CareerLine.SHADOW_WARRIOR]  = AB_const.ORDER,

    [GameData.CareerLine.WITCH_ELF]       = AB_const.DESTRUCTION,
    [GameData.CareerLine.WHITE_LION]      = AB_const.ORDER,
    [GameData.CareerLine.SLAYER]          = AB_const.ORDER,
    [GameData.CareerLine.WITCH_HUNTER]    = AB_const.ORDER,
    [GameData.CareerLine.CHOPPA]          = AB_const.DESTRUCTION,
    [GameData.CareerLine.MARAUDER]        = AB_const.DESTRUCTION,

    [GameData.CareerLine.IRON_BREAKER]    = AB_const.ORDER,
    [GameData.CareerLine.CHOSEN]          = AB_const.DESTRUCTION,
    [GameData.CareerLine.BLACK_ORC]       = AB_const.DESTRUCTION,
    [GameData.CareerLine.KNIGHT]          = AB_const.ORDER,
    [GameData.CareerLine.SWORDMASTER]     = AB_const.ORDER,
    [GameData.CareerLine.BLACKGUARD]      = AB_const.DESTRUCTION,

    [GameData.CareerLine.ZEALOT]          = AB_const.DESTRUCTION,
    [GameData.CareerLine.WARRIOR_PRIEST]  = AB_const.ORDER,
    [GameData.CareerLine.RUNE_PRIEST]     = AB_const.ORDER,
    [GameData.CareerLine.ARCHMAGE]        = AB_const.ORDER,
    [GameData.CareerLine.SHAMAN]          = AB_const.DESTRUCTION,
    [GameData.CareerLine.DISCIPLE]        = AB_const.DESTRUCTION
}


AB_const.CAREER_NAME_BW = "Bright Wizards"
AB_const.CAREER_NAME_SORC = "Sorcerers"
AB_const.CAREER_NAME_WH = "Witch Hunters"
AB_const.CAREER_NAME_WE = "Witch Elves"

function AB_const.GetBWSorcAsMDPSLabel()
    if AutoBand.faction == AB_const.ORDER then
        return AB_const.CAREER_NAME_BW .. " as mDPS"
    elseif AutoBand.faction == AB_const.DESTRUCTION then
        return AB_const.CAREER_NAME_SORC .. " as mDPS"
    else
        return "BW/Sorc as mDPS" -- Fallback
    end
end

function AB_const.GetAutoKickStealthersLabel(prefix)
    local label_prefix = prefix or "AKick"
    if AutoBand and AutoBand.faction == AB_const.ORDER then
        return label_prefix .. " " .. AB_const.CAREER_NAME_WH
    elseif AutoBand and AutoBand.faction == AB_const.DESTRUCTION then
        return label_prefix .. " " .. AB_const.CAREER_NAME_WE
    end
    return label_prefix .. " stealthers"
end

function AB_const.GetRestrictRaceLabel()
    if AutoBand.raceDetermined then
        return "Restrict to " .. AB_const.GetRaceThemeTitle(AutoBand.race) .. " Only"
    else
        return "Restrict to Leader's Race" -- Fallback
    end
end

function AB_const.GetExcludeRealmHealerAltSpecLabel()
    if AutoBand and AutoBand.faction == AB_const.ORDER then
        return "Exclude RPs"
    elseif AutoBand and AutoBand.faction == AB_const.DESTRUCTION then
        return "Exclude Zeal"
    end
    return "Exclude RP/Zealot"
end

-- Tooltip for the Exclude checkbox: the full career name of the realm healer.
function AB_const.GetExcludeRealmHealerAltSpecTooltip()
    if AutoBand and AutoBand.faction == AB_const.ORDER then
        return "Skips Rune Priests in the alt-spec check."
    elseif AutoBand and AutoBand.faction == AB_const.DESTRUCTION then
        return "Skips Zealots in the alt-spec check."
    end
    return "Skips Rune Priests/Zealots in the alt-spec check."
end

AB_const.FAKE_PLAYERS = {
    [AB_const.HEALER] = {
        ["careerLine"] = GameData.CareerLine.ZEALOT,
        ["online"] = true
    },
    [AB_const.TANK] = {
        ["careerLine"] = GameData.CareerLine.CHOSEN,
        ["online"] = true
    },
    [AB_const.MDPS] = {
        ["careerLine"] = GameData.CareerLine.CHOPPA,
        ["online"] = true
    },
    [AB_const.RDPS] = {
        ["careerLine"] = GameData.CareerLine.SORCERER,
        ["online"] = true
    }
}

AB_const.ROLE_CATEGORIES = {
    [AB_const.HEALER] = 1,
    [AB_const.TANK]   = 2,
    [AB_const.MDPS]   = 3,
    [AB_const.RDPS]   = 4
}

AB_const.MODE_SPREAD = 1
AB_const.MODE_AGGREGATE = 2
AB_const.ALGO_MODE = {
    [AB_const.MODE_SPREAD]    = "Spread categories",
    [AB_const.MODE_AGGREGATE] = "Aggregate categories"
}

AB_const.DEFAULT_ORG_ALGO = AB_const.MODE_SPREAD -- distributing equally
AB_const.DEFAULT_ORG_ROLE = AB_const.HEALER
AB_const.LOOP_MAX = 100

AB_const.TABS_TEMPLATE = 1
AB_const.TABS_TOOLS = 2
AB_const.TABS_CONFIG = 3
AB_const.TABS_REALM = 4

AB_const.LABEL_EMPTY = "---"
AB_const.LABEL_ROLE_COLORS = {
    [AB_const.HEALER]     = { 0, 210, 0 },
    [AB_const.TANK]       = { 0, 0, 210 },
    [AB_const.MDPS]       = { 210, 0, 0 },
    [AB_const.RDPS]       = { 210, 0, 210 },
    [AB_const.LABEL_EMPTY]= { 210, 210, 210 }
}
AB_const.LABEL_ROLE_CATEGORIES = {
    [AB_const.HEALER]      = 1,
    [AB_const.TANK]        = 2,
    [AB_const.MDPS]        = 3,
    [AB_const.RDPS]        = 4,
    [AB_const.LABEL_EMPTY] = 5
}
AB_const.LABEL_ROLE_CATEGORIES_REV = {
    AB_const.HEALER,
    AB_const.TANK,
    AB_const.MDPS,
    AB_const.RDPS,
    AB_const.LABEL_EMPTY
}

-- Define icon variables
AB_const.ICONS = {
    am     = "<icon20180>",
    bg     = "<icon20181>",
    bo     = "<icon20182>",
    bw     = "<icon20183>",
    chp    = "<icon20184>",
    cho    = "<icon20185>",
    dok    = "<icon20186>",
    eng    = "<icon20187>",
    sl     = "<icon20188>",
    ib     = "<icon20189>",
    kotbs  = "<icon20190>",
    mag    = "<icon20191>",
    mara   = "<icon20192>",
    rp     = "<icon20193>",
    sw     = "<icon20194>",
    sha    = "<icon20195>",
    sorc   = "<icon20196>",
    sh     = "<icon20197>",
    sm     = "<icon20198>",
    wp     = "<icon20199>",
    wl     = "<icon20200>",
    we     = "<icon20201>",
    wh     = "<icon20202>",
    ze     = "<icon20203>",
    dps    = "<icon22701>",
    healer = "<icon22706>",
    mdps   = "<icon22701>",
    rdps   = "<icon22703>",
    tank   = "<icon22702>",
    prefix = "<icon44> ",
    suffix = " <icon44>",
    [AB_const.DWARFS] = "<icon22733>",
    [AB_const.EMPIRE] = "<icon22732>",
    [AB_const.HIGHELVES] = "<icon22727>",
    [AB_const.CHAOS] = "<icon22652>",
    [AB_const.DARKELVES] = "<icon22657>",
    [AB_const.GREENSKINS] = "<icon23008>",
}

AB_const.CAREERLINE_ICON_MAP = {
    [GameData.CareerLine.ENGINEER]        = AB_const.ICONS.eng,
    [GameData.CareerLine.BRIGHT_WIZARD]   = AB_const.ICONS.bw,
    [GameData.CareerLine.SORCERER]        = AB_const.ICONS.sorc,
    [GameData.CareerLine.SQUIG_HERDER]    = AB_const.ICONS.sh,
    [GameData.CareerLine.MAGUS]           = AB_const.ICONS.mag,
    [GameData.CareerLine.SHADOW_WARRIOR]  = AB_const.ICONS.sw,

    [GameData.CareerLine.WITCH_ELF]       = AB_const.ICONS.we,
    [GameData.CareerLine.WHITE_LION]      = AB_const.ICONS.wl,
    [GameData.CareerLine.SLAYER]          = AB_const.ICONS.sl,
    [GameData.CareerLine.WITCH_HUNTER]    = AB_const.ICONS.wh,
    [GameData.CareerLine.CHOPPA]          = AB_const.ICONS.chp,
    [GameData.CareerLine.MARAUDER]        = AB_const.ICONS.mara,

    [GameData.CareerLine.IRON_BREAKER]    = AB_const.ICONS.ib,
    [GameData.CareerLine.CHOSEN]          = AB_const.ICONS.cho,
    [GameData.CareerLine.BLACK_ORC]       = AB_const.ICONS.bo,
    [GameData.CareerLine.KNIGHT]          = AB_const.ICONS.kotbs,
    [GameData.CareerLine.SWORDMASTER]     = AB_const.ICONS.sm,
    [GameData.CareerLine.BLACKGUARD]      = AB_const.ICONS.bg,

    [GameData.CareerLine.ZEALOT]          = AB_const.ICONS.ze,
    [GameData.CareerLine.WARRIOR_PRIEST]  = AB_const.ICONS.wp,
    [GameData.CareerLine.RUNE_PRIEST]     = AB_const.ICONS.rp,
    [GameData.CareerLine.ARCHMAGE]        = AB_const.ICONS.am,
    [GameData.CareerLine.SHAMAN]          = AB_const.ICONS.sha,
    [GameData.CareerLine.DISCIPLE]        = AB_const.ICONS.dok
}

AB_const.RACE_CAREER_ROLE_ICONS = {
    [AB_const.ORDER] = {
        [AB_const.DWARFS] = {
            tank   = AB_const.ICONS.ib,
            healer = AB_const.ICONS.rp,
            mdps   = AB_const.ICONS.sl,
            rdps   = AB_const.ICONS.eng .. "" .. AB_const.ICONS.rp,
            dps    = AB_const.ICONS.sl .. "" .. AB_const.ICONS.eng .. "" .. AB_const.ICONS.rp
        },
        [AB_const.EMPIRE] = {
            tank   = AB_const.ICONS.kotbs,
            healer = AB_const.ICONS.wp,
            mdps   = AB_const.ICONS.wh .. "" .. AB_const.ICONS.wp,
            rdps   = AB_const.ICONS.bw,
            dps    = AB_const.ICONS.wh .. "" .. AB_const.ICONS.bw .. "" .. AB_const.ICONS.wp
        },
        [AB_const.HIGHELVES] = {
            tank   = AB_const.ICONS.sm,
            healer = AB_const.ICONS.am,
            mdps   = AB_const.ICONS.wl .. "" .. AB_const.ICONS.sw,
            rdps   = AB_const.ICONS.sw .. "" .. AB_const.ICONS.am,
            dps    = AB_const.ICONS.wl .. "" .. AB_const.ICONS.sw .. "" .. AB_const.ICONS.am
        }
    },
    [AB_const.DESTRUCTION] = {
        [AB_const.CHAOS] = {
            tank   = AB_const.ICONS.cho,
            healer = AB_const.ICONS.ze,
            mdps   = AB_const.ICONS.mara,
            rdps   = AB_const.ICONS.mag .. "" .. AB_const.ICONS.ze,
            dps    = AB_const.ICONS.mara .. "" .. AB_const.ICONS.mag .. "" .. AB_const.ICONS.ze
        },
        [AB_const.DARKELVES] = {
            tank   = AB_const.ICONS.bg,
            healer = AB_const.ICONS.dok,
            mdps   = AB_const.ICONS.we .. "" .. AB_const.ICONS.dok,
            rdps   = AB_const.ICONS.sorc,
            dps    = AB_const.ICONS.we .. "" .. AB_const.ICONS.sorc .. "" .. AB_const.ICONS.dok
        },
        [AB_const.GREENSKINS] = {
            tank   = AB_const.ICONS.bo,
            healer = AB_const.ICONS.sha,
            mdps   = AB_const.ICONS.chp .. "" .. AB_const.ICONS.sh,
            rdps   = AB_const.ICONS.sh .. "" .. AB_const.ICONS.sha,
            dps    = AB_const.ICONS.chp .. "" .. AB_const.ICONS.sh .. "" .. AB_const.ICONS.sha
        }
    }
}

AB_const.CURRENT_WB = "<Warband>"
AB_const.MAX_KICKOFF_TIME = 9
AB_const.LABEL_NOTSAMEZONE = "Players not in leader's / assistants' zone"

AB_const.KICK_OFFLINE = 1
AB_const.KICK_ZONE = 2
AB_const.KICK_RANK = 3
AB_const.KICK_RACE = 4

AB_const.KICK_FUNC_DEFAULT = {
    [AB_const.KICK_OFFLINE] = false,
    [AB_const.KICK_ZONE]    = false,
    [AB_const.KICK_RANK]    = false,
    [AB_const.KICK_RACE]    = false
}

-- ZONEIDS
-- Purpose: Policy allowlist for "RvR/City" zones.
-- - Used to build `AutoBand.allowed_rvr_zones_set` during init.
-- - Referenced by autokick logic (e.g., kick players outside allowed zones).
-- - NOT used for naming; see ZONE_NAME_OVERRIDES for label fallbacks.
-- Maintenance tips:
-- - Keep this focused on zones relevant to policy (RvR/City/etc.).
-- - This list may be a subset of all game zones and is independent of naming.
AB_const.ZONEIDS = {
    --Dwarfs vs Greenskins
    6, -- "Ekrund"
    11, -- "Mount Bloodhorn"
    7, -- "Barak Varr"
    1, -- "Marshes of Madness"
    2, -- "The Badlands"
    8, -- "Black Fire Pass"
    9, -- "Kadrin Valley"
    5, -- "Thunder Mountain"
    3, -- "Black Crag"
    26, -- "Cinderfall"
    27, -- "Death Peak"

    -- Forts
    4, -- "Butcher's Pass"
    10, -- "Stonewatch"

    --Chaos vs Empire
    100, -- "Norsca"
    106, -- "Nordland"
    107, -- "Ostland"
    101, -- "Troll Country"
    102, -- "High Pass"
    108, -- "Talabecland"
    103, -- "Chaos Wastes"
    105, -- "Praag"
    109, -- "Reikland"
    120, -- "West Praag"

    -- Forts
    104, -- "The Maw"
    110, -- "Reikwald"

    --Cities
    61, -- "Karak Eight Peaks"
    96, -- "Karak Eight Peaks Da Deeps"
    62, -- "Karaz-a-Karak"
    68, -- "Karaz-a-Karak"
    97, -- "Karaz-a-Karak Middle Deeps"
    161, -- "The Inevitable City"
    162, -- "Altdorf"
    170, -- "Altdorf Palace"
    172, -- "The Eternal Citadel"
    178, -- "The Viper Pit"
    198, -- "Sigmar's Hammer"

    --Land of the Dead
    191, -- "Necropolis of Zandri"
    413, -- "Garden of Qu'aph"

    --High Elves vs Dark Elves
    200, -- "The Blighted Isle"
    206, -- "Chrace"
    201, -- "The Shadowlands"
    207, -- "Ellyrion"
    202, -- "Avelorn"
    208, -- "Saphery"
    203, -- "Caledor"
    205, -- "Dragonwake"
    209, -- "Eataine"
    220, -- "Isle of the Dead"

    -- Forts
    204, -- "Fell Landing"
    210, -- "Shining Way"
};

-- CAMPAIGN_ZONE_PAIRINGS
-- Purpose: Symmetric T1/T2/T3 campaign neighbor mapping.
-- - Used by zone safety checks (leader/assistant zone kick/list logic).
-- - Keep symmetric: if [A] = B, [B] must also equal A.
AB_const.CAMPAIGN_ZONE_PAIRINGS = {
    -- Tier 1
    [6]   = 11, [11]  = 6,   -- Ekrund <-> Mount Bloodhorn
    [106] = 100,[100] = 106, -- Nordland <-> Norsca
    [200] = 206,[206] = 200, -- The Blighted Isle <-> Chrace

    -- Tier 2
    [7]   = 1,  [1]   = 7,   -- Barak Varr <-> Marshes of Madness
    [107] = 101,[101] = 107, -- Ostland <-> Troll Country
    [201] = 207,[207] = 201, -- The Shadowlands <-> Ellyrion

    -- Tier 3
    [2]   = 8,  [8]   = 2,   -- The Badlands <-> Black Fire Pass
    [102] = 108,[108] = 102, -- High Pass <-> Talabecland
    [202] = 208,[208] = 202, -- Avelorn <-> Saphery
}

-- Optional short labels for paired-zone advert text.
-- Used only when we display both zones for a campaign pair.
AB_const.ZONE_PAIR_SHORT_NAMES = {
    [1]   = "MoM", -- Marshes of Madness
    [101] = "TC",  -- Troll Country
    [8]   = "BFP", -- Black Fire Pass
    [102] = "HP",  -- High Pass
}

-- Broad campaign labels for places where exact zone text would be misleading.
-- Label-only; zone safety and paired-zone policy still use their own maps.
AB_const.CAMPAIGN_ZONE_SCOPE_LABELS = {
    -- Tier 1
    [6]   = { [AB_const.ORDER] = "Dwarf T1", [AB_const.DESTRUCTION] = "Greenskin T1", default = "T1" },
    [11]  = { [AB_const.ORDER] = "Dwarf T1", [AB_const.DESTRUCTION] = "Greenskin T1", default = "T1" },
    [100] = { [AB_const.ORDER] = "Empire T1", [AB_const.DESTRUCTION] = "Chaos T1", default = "T1" },
    [106] = { [AB_const.ORDER] = "Empire T1", [AB_const.DESTRUCTION] = "Chaos T1", default = "T1" },
    [200] = { [AB_const.ORDER] = "High Elf T1", [AB_const.DESTRUCTION] = "Dark Elf T1", default = "T1" },
    [206] = { [AB_const.ORDER] = "High Elf T1", [AB_const.DESTRUCTION] = "Dark Elf T1", default = "T1" },

    -- Tier 2
    [1]   = { [AB_const.ORDER] = "Dwarf T2", [AB_const.DESTRUCTION] = "Greenskin T2", default = "T2" },
    [7]   = { [AB_const.ORDER] = "Dwarf T2", [AB_const.DESTRUCTION] = "Greenskin T2", default = "T2" },
    [101] = { [AB_const.ORDER] = "Empire T2", [AB_const.DESTRUCTION] = "Chaos T2", default = "T2" },
    [107] = { [AB_const.ORDER] = "Empire T2", [AB_const.DESTRUCTION] = "Chaos T2", default = "T2" },
    [201] = { [AB_const.ORDER] = "High Elf T2", [AB_const.DESTRUCTION] = "Dark Elf T2", default = "T2" },
    [207] = { [AB_const.ORDER] = "High Elf T2", [AB_const.DESTRUCTION] = "Dark Elf T2", default = "T2" },

    -- Tier 3
    [2]   = { [AB_const.ORDER] = "Dwarf T3", [AB_const.DESTRUCTION] = "Greenskin T3", default = "T3" },
    [8]   = { [AB_const.ORDER] = "Dwarf T3", [AB_const.DESTRUCTION] = "Greenskin T3", default = "T3" },
    [102] = { [AB_const.ORDER] = "Empire T3", [AB_const.DESTRUCTION] = "Chaos T3", default = "T3" },
    [108] = { [AB_const.ORDER] = "Empire T3", [AB_const.DESTRUCTION] = "Chaos T3", default = "T3" },
    [202] = { [AB_const.ORDER] = "High Elf T3", [AB_const.DESTRUCTION] = "Dark Elf T3", default = "T3" },
    [208] = { [AB_const.ORDER] = "High Elf T3", [AB_const.DESTRUCTION] = "Dark Elf T3", default = "T3" },

    -- Tier 4
    [3]   = { [AB_const.ORDER] = "Dwarf T4", [AB_const.DESTRUCTION] = "Greenskin T4", default = "T4" },
    [5]   = { [AB_const.ORDER] = "Dwarf T4", [AB_const.DESTRUCTION] = "Greenskin T4", default = "T4" },
    [9]   = { [AB_const.ORDER] = "Dwarf T4", [AB_const.DESTRUCTION] = "Greenskin T4", default = "T4" },
    [103] = { [AB_const.ORDER] = "Empire T4", [AB_const.DESTRUCTION] = "Chaos T4", default = "T4" },
    [105] = { [AB_const.ORDER] = "Empire T4", [AB_const.DESTRUCTION] = "Chaos T4", default = "T4" },
    [109] = { [AB_const.ORDER] = "Empire T4", [AB_const.DESTRUCTION] = "Chaos T4", default = "T4" },
    [203] = { [AB_const.ORDER] = "High Elf T4", [AB_const.DESTRUCTION] = "Dark Elf T4", default = "T4" },
    [205] = { [AB_const.ORDER] = "High Elf T4", [AB_const.DESTRUCTION] = "Dark Elf T4", default = "T4" },
    [209] = { [AB_const.ORDER] = "High Elf T4", [AB_const.DESTRUCTION] = "Dark Elf T4", default = "T4" },

    -- Forts
    [4]   = "Butcher's Pass",
    [10]  = "Stonewatch",
    [104] = "The Maw",
    [110] = "Reikwald",
    [204] = "Fell Landing",
    [210] = "Shining Way",
}

-- Optional explicit name fixes for zones that render poorly via GetZoneName.
-- Keep ASCII-only; fill only if needed.
-- ZONE_NAME_OVERRIDES
-- Purpose: Fallback ID -> ASCII name map for zone labels.
-- - Used only when engine `GetZoneName(zid)` yields empty/botched text.
-- - Naming pipeline: engine name -> AutoBand.FixString (strip ^suffix) -> sanitize.
--   If that fails, we look here; otherwise we show "Unknown Zone (id)".
-- - Independent from ZONEIDS (policy). This map can be a superset.
-- Maintenance tips:
-- - Add entries when you observe broken names in chat/logs.
-- - Keep names ASCII-safe; avoid tags or non-UI glyphs.
AB_const.ZONE_NAME_OVERRIDES = {
    -- Dwarfs vs Greenskins
    [6]   = "Ekrund",
    [11]  = "Mount Bloodhorn",
    [7]   = "Barak Varr",
    [1]   = "Marshes of Madness",
    [2]   = "The Badlands",
    [8]   = "Black Fire Pass",
    [9]   = "Kadrin Valley",
    [5]   = "Thunder Mountain",
    [3]   = "Black Crag",
    [26]  = "Cinderfall",
    [27]  = "Death Peak",

    -- Forts
    [4]   = "Butcher's Pass",
    [10]  = "Stonewatch",

    -- Chaos vs Empire
    [100] = "Norsca",
    [106] = "Nordland",
    [107] = "Ostland",
    [101] = "Troll Country",
    [102] = "High Pass",
    [108] = "Talabecland",
    [103] = "Chaos Wastes",
    [105] = "Praag",
    [109] = "Reikland",
    [120] = "West Praag",

    -- Forts
    [104] = "The Maw",
    [110] = "Reikwald",

    -- Cities
    [61]  = "Karak Eight Peaks",
    [96]  = "Karak Eight Peaks Da Deeps",
    [62]  = "Karaz-a-Karak",
    [68]  = "Karaz-a-Karak",
    [97]  = "Karaz-a-Karak Middle Deeps",
    [161] = "The Inevitable City",
    [162] = "Altdorf",
    [170] = "Altdorf Palace",
    [172] = "The Eternal Citadel",
    [178] = "The Viper Pit",
    [198] = "Sigmar's Hammer",

    -- Land of the Dead
    [191] = "Necropolis of Zandri",
    [413] = "Garden of Qu'aph",

    -- High Elves vs Dark Elves
    [200] = "The Blighted Isle",
    [206] = "Chrace",
    [201] = "The Shadowlands",
    [207] = "Ellyrion",
    [202] = "Avelorn",
    [208] = "Saphery",
    [203] = "Caledor",
    [205] = "Dragonwake",
    [209] = "Eataine",
    [220] = "Isle of the Dead",

    -- Forts
    [204] = "Fell Landing",
    [210] = "Shining Way",
}
