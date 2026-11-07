<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UiMod name="AutoBand" version="0.9.83" date="2026-11-07">
	<Author name="Differential, Eowoyn, Botanich, Talladego, Wholdar, Ninjas and Kpihuss" email="no@way" />
	<VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />
	<Description text="Automated Warband composition tool with role balancing, auto-kick rules, templates, and in-game GUI." />

    <WARInfo>
        <Categories>
            <Category name="GROUPING" />
        </Categories>
    </WARInfo>

    <Dependencies>
        <Dependency name="LibSlash"/>
        <Dependency name="EASystem_Strings"/>
        <Dependency name="EASystem_WindowUtils"/>
    </Dependencies>

    <Files>
        <File name="AB_const.lua"/>
        <File name="AutoBand.lua"/>
        <File name="AB_zonevote.lua"/>
        <File name="AB_scoreboard.lua"/>
        <File name="AB_wbleaders.lua"/>
        <File name="AB_realmrank.lua"/>
        <File name="AB_realmrank_runtime.lua"/>
        <File name="AB_realmrank_commands.lua"/>
        <File name="AB_stats.lua"/>
        <File name="AB_stats_runtime.lua"/>
        <File name="AB_stats_commands.lua"/>
        <File name="AB_org.lua"/>
        <File name="AB_util.lua"/>
        <File name="AB_wb.lua"/>
        <File name="AB_template.lua"/>
        
        <File name="AutoBandWindowCommon.lua"/>
        <File name="AutoBandWindowTemplate.xml" />
        <File name="AutoBandWindowConfig.xml" />
        <File name="AutoBandWindowTools.xml" /> 
        <File name="AutoBandWindowRealm.xml" />
        <File name="AutoBandWindow.xml"/>
        
    </Files>

    <SavedVariables>
        <SavedVariable name="AutoBand.saved"/>
    </SavedVariables>

    <OnInitialize>
        <CreateWindow name="AutoBandMapIcon" show="true"/>
        <CallFunction name="AutoBand.init"/>
        <CreateWindow name="AutoBandWindow" show="false"/>
        <CreateWindow name="AutoBandWindowTemplateSave" show="false"/>
        <CreateWindow name="AutoBandWindowTemplateDeleteConfirm" show="false"/>
        <CreateWindow name="AutoBandWindowLeaderPromotionPopup" show="false"/>
        <CreateWindow name="AutoBandWindowScoreboardPreview" show="false"/>
    </OnInitialize>

    <OnUpdate>
        <CallFunction name="AutoBand.update"/>
    </OnUpdate>

        <OnShutdown>
                <CallFunction name="AutoBand.Shutdown"/>
        </OnShutdown>
</UiMod>
</ModuleFile>
