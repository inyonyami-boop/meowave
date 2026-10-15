-- Level 1 专属场景配置；共享玩法不在这里复制。
-- 术语：“九窗”= windows 的九个窗洞矩形；文案与素材路径在此集中声明。
return {
    number = 1, catLimit = 6,
    tutorial = "Level1/Text/level_1.txt",
    resultText = {
        victory = "Global/Text/通关锦旗文案.txt",
        blackBanner = "Global/Text/黑锦旗文案.txt",
        letter = "Global/Text/威胁信文案.txt",
    },
    width = 12, height = 7.5, groundY = 5.4,
    buildingWidth = 672, buildingHeight = 1992,
    buildingRect = { x = 36 / 7, y = 0, w = 12 / 7, h = 5.4 },
    windows = {
        { x = 91, y = 259, w = 105, h = 144 }, { x = 283, y = 259, w = 106, h = 145 },
        { x = 475, y = 259, w = 104, h = 144 },
        { x = 91, y = 743, w = 106, h = 145 }, { x = 283, y = 745, w = 106, h = 143 },
        { x = 475, y = 744, w = 104, h = 145 },
        { x = 91, y = 1221, w = 106, h = 144 }, { x = 283, y = 1221, w = 106, h = 144 },
        { x = 475, y = 1222, w = 104, h = 143 },
    },
    house = "Level1/Images/HouseFairytale.png",
    grass = "Level1/Images/GrassFairytale.png",
}

