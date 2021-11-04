#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smlib>

#pragma semicolon 1

#define BOT_NAME_FILE			"configs/botnames.cfg"
#define BOT_RESTRICTIONS_FILE	"configs/botrestrictions.cfg"

// this array will store the names loaded
new Handle:bot_names;

// this array will have a list of indexes to
// bot_names, use these in order
new Handle:name_redirects;

char g_sRestrictedWeapons[64][64];
int g_iRestrictedWeapons = 0;

// this is the next index to use into name_redirects
// update this each time you use a name
new next_index;

// Entities
new g_iPlayerResourceEntity	= -1;

// Offsets
new g_iPing				= -1;

// Timers
new Handle:g_hPingTimer = INVALID_HANDLE;

// ConVars
new Handle:g_hMinPing	= INVALID_HANDLE;
new Handle:g_hMaxPing	= INVALID_HANDLE;
new Handle:g_hInterval	= INVALID_HANDLE;
new Handle:g_hPrefix	= INVALID_HANDLE;
new Handle:g_hRandom	= INVALID_HANDLE;
new Handle:g_hAnnounce	= INVALID_HANDLE;
new Handle:g_hSuppress	= INVALID_HANDLE;

public Plugin:myinfo =
{
	name = "BotManager",
	author = "Rakeri, Knagg0, maxime1907",
	description = "Manage bot's name, ping and weapon restictions",
	version = "1.1",
	url = ""
}

public void OnPluginStart()
{
	g_hPrefix = CreateConVar("sm_botmanager_prefix", "", "Prefix for bot names (include a trailing space, if needed!)", FCVAR_NOTIFY);
	g_hRandom = CreateConVar("sm_botmanager_random", "1", "Randomize names used", FCVAR_NOTIFY);
	g_hAnnounce = CreateConVar("sm_botmanager_announce", "1", "Announce bots when added", FCVAR_NOTIFY);
	g_hSuppress = CreateConVar("sm_botmanager_suppress", "1", "Supress join/team change/name change bot messages", FCVAR_NOTIFY);
	g_hMinPing	= CreateConVar("sm_botmanager_minping", "50", "Minimum ping of the bot", FCVAR_NOTIFY);
	g_hMaxPing	= CreateConVar("sm_botmanager_maxping", "75", "Maximum ping of the bot", FCVAR_NOTIFY);
	g_hInterval	= CreateConVar("sm_botmanager_interval", "3.0", "The number of seconds to wait before a ping change", FCVAR_NOTIFY);

	// register our commands
	RegServerCmd("sm_botmanager_reload", Command_Reload);

	// hook team change, connect to supress messages
	HookEvent("player_connect", Event_PlayerConnect, EventHookMode_Pre);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);

	// trickier... name changes are user messages, so...
	HookUserMessage(GetUserMessageId("SayText2"), UserMessage_SayText2, true);

	g_iPing	= FindSendPropInfo("CPlayerResource", "m_iPing");

	LoadWeaponRestrictions();

	AutoExecConfig(true);
}

public void OnPluginEnd()
{
	if (g_hPingTimer != INVALID_HANDLE)
	{
		KillTimer(g_hPingTimer);
		g_hPingTimer = INVALID_HANDLE;
	}
}

public void OnConfigsExecuted()
{
	g_hPingTimer = CreateTimer(GetConVarFloat(g_hInterval), ChangeBotsPing, _, TIMER_REPEAT);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquip);
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_WeaponEquipPost, OnWeaponEquip);
}

public void OnMapStart()
{
	g_iPlayerResourceEntity = GetPlayerResourceEntity();
	ReloadNames();
	GenerateRedirects();
}

// reload bot name, via console
public Action:Command_Reload(args)
{
	LoadWeaponRestrictions();
	ReloadNames();
	GenerateRedirects();
	PrintToServer("[BotManager] Loaded %i names and restricted.", GetArraySize(bot_names));
}

// handle client connection, to change the names...
public bool:OnClientConnect(client, String:rejectmsg[], maxlen)
{
	new loaded_names = GetArraySize(bot_names);

	if (IsFakeClient(client) && !IsClientSourceTV(client) && loaded_names != 0)
	{
		// we got a bot, here, boss
		
		decl String:newname[MAX_NAME_LENGTH];
		GetArrayString(bot_names, GetArrayCell(name_redirects, next_index), newname, MAX_NAME_LENGTH);

		next_index++;
		if (next_index > loaded_names - 1)
		{
			next_index = 0;
		}
		
		SetClientInfo(client, "name", newname);
		if (GetConVarBool(g_hAnnounce))
		{
			PrintToChatAll("[botnames] Bot %s created.", newname);
			PrintToServer("[botnames] Bot %s created.", newname);
		}
	}
	return true;
}

// handle "SayText2" usermessages, including name change notifies!
public Action:UserMessage_SayText2(UserMsg:msg_id, Handle:bf, const players[], playersNum, bool:reliable, bool:init)
{
	if (!GetConVarBool(g_hSuppress))
	{
		return Plugin_Continue;
	}

	decl String:message[256];

	BfReadShort(bf); // team color

	BfReadString(bf, message, sizeof(message));
	// check for Name_Change, not #TF_Name_Change (compatibility?)
	if (StrContains(message, "Name_Change") != -1)
	{
		BfReadString(bf, message, sizeof(message)); // original
		BfReadString(bf, message, sizeof(message)); // new
		if (FindStringInArray(bot_names, message) != -1)
		{
			// 'tis a bot!
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

// handle player team change, to supress bot messages
public Action:Event_PlayerTeam(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!GetConVarBool(g_hSuppress))
	{
		return Plugin_Continue;
	}

	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client == 0)
	{
		// weird error, ignore
		return Plugin_Continue;
	}
	if (IsFakeClient(client) && !IsClientSourceTV(client))
	{
		// fake client == bot
		SetEventBool(event, "silent", true);
		return Plugin_Changed;
	}

	return Plugin_Continue;
}

// handle player connect, to supress bot messages
public Action:Event_PlayerConnect(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!GetConVarBool(g_hSuppress))
	{
		return Plugin_Continue;
	}

	decl String:networkID[32];
	GetEventString(event, "networkid", networkID, sizeof(networkID));

	if(!dontBroadcast && StrEqual(networkID, "BOT"))
	{
		// we got a bot connectin', resend event as no-broadcast
		decl String:clientName[MAX_NAME_LENGTH], String:address[32];
		GetEventString(event, "name", clientName, sizeof(clientName));
		GetEventString(event, "address", address, sizeof(address));

		new Handle:newEvent = CreateEvent("player_connect", true);
		SetEventString(newEvent, "name", clientName);
		SetEventInt(newEvent, "index", GetEventInt(event, "index"));
		SetEventInt(newEvent, "userid", GetEventInt(event, "userid"));
		SetEventString(newEvent, "networkid", networkID);
		SetEventString(newEvent, "address", address);

		FireEvent(newEvent, true);

		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public Action OnWeaponEquip(int client, int entity)
{
	if(!IsValidEntity(entity))
		return;

	int HammerID = GetEntProp(entity, Prop_Data, "m_iHammerID");
	// Should not be cleaned since it's a map spawned weapon
	if(HammerID)
		return;

	// Check if its a valid client
	if (!IsValidEdict(client) || !IsClientInGame(client) || !IsFakeClient(client) || IsClientSourceTV(client))
		return;

	char sClassName[64];
	GetEntityClassname(entity, sClassName,sizeof(sClassName));

	for (int i = 0; i < g_iRestrictedWeapons; i++)
	{
		if (StrEqual(g_sRestrictedWeapons[i], sClassName, true))
			Client_RemoveWeapon(client, sClassName, false, true);
	}
}

stock Action ChangeBotsPing(Handle:timer)
{
	if (g_iPlayerResourceEntity == -1 || g_iPing == -1)
		return Plugin_Continue;

	for (new i = 1; i <= MaxClients; i++)
	{
		if(!IsValidEdict(i) || !IsClientInGame(i) || !IsFakeClient(i) || IsClientSourceTV(i))
			continue;

		SetEntData(g_iPlayerResourceEntity, g_iPing + (i * 4), GetRandomInt(GetConVarInt(g_hMinPing), GetConVarInt(g_hMaxPing)));
	}
	return Plugin_Continue;
}

// a function to generate name_redirects
stock void GenerateRedirects()
{
	new loaded_names = GetArraySize(bot_names);

	if (name_redirects != INVALID_HANDLE)
	{
		ResizeArray(name_redirects, loaded_names);
	} else {
		name_redirects = CreateArray(1, loaded_names);
	}

	for (new i = 0; i < loaded_names; i++)
	{
		SetArrayCell(name_redirects, i, i);
		
		// nothing to do random-wise if i == 0
		if (i == 0)
		{
			continue;
		}

		// now to introduce some chaos
		if (GetConVarBool(g_hRandom))
		{
			SwapArrayItems(name_redirects, GetRandomInt(0, i - 1), i);
		}
	}
}

// a function to load data into bot_names
stock void ReloadNames()
{
	next_index = 0;
	decl String:path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), BOT_NAME_FILE);
	
	if (bot_names != INVALID_HANDLE)
	{
		ClearArray(bot_names);
	} else {
		bot_names = CreateArray(MAX_NAME_LENGTH);
	}
	
	new Handle:file = OpenFile(path, "r");
	if (file == INVALID_HANDLE)
	{
		//PrintToServer("bot name file unopened");
		return;
	}
	
	// this LENGTH*3 is sort of a hack
	// don't make long lines, people!
	decl String:newname[MAX_NAME_LENGTH*3];
	decl String:formedname[MAX_NAME_LENGTH];
	decl String:prefix[MAX_NAME_LENGTH];

	GetConVarString(g_hPrefix, prefix, MAX_NAME_LENGTH);

	while (IsEndOfFile(file) == false)
	{
		if (ReadFileLine(file, newname, sizeof(newname)) == false)
		{
			break;
		}
		
		// trim off comments starting with // or #
		new commentstart;
		commentstart = StrContains(newname, "//");
		if (commentstart != -1)
		{
			newname[commentstart] = 0;
		}
		commentstart = StrContains(newname, "#");
		if (commentstart != -1)
		{
			newname[commentstart] = 0;
		}
		
		new length = strlen(newname);
		if (length < 2)
		{
			// we loaded a bum name
			// (that is, blank line or 1 char == bad)
			//PrintToServer("bum name");
			continue;
		}

		// get rid of pesky whitespace
		TrimString(newname);
		
		Format(formedname, MAX_NAME_LENGTH, "%s%s", prefix, newname);
		PushArrayString(bot_names, formedname);
	}
	
	CloseHandle(file);
}

stock void LoadWeaponRestrictions()
{
	g_iRestrictedWeapons = 0;
	for (int i = 0; i < sizeof(g_sRestrictedWeapons); i++)
		g_sRestrictedWeapons[i] = "";

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), BOT_RESTRICTIONS_FILE);

	File file = OpenFile(path, "r");
	if (file == INVALID_HANDLE)
	{
		LogError("Couldnt find %s", BOT_RESTRICTIONS_FILE);
		return;
	}

	char sWeaponName[64] = "";
	while (!IsEndOfFile(file))
	{
		if (!ReadFileLine(file, sWeaponName, sizeof(sWeaponName)))
			break;
		
		// trim off comments starting with // or #
		int commentstart;
		commentstart = StrContains(sWeaponName, "//");
		if (commentstart != -1)
			sWeaponName[commentstart] = 0;

		commentstart = StrContains(sWeaponName, "#");
		if (commentstart != -1)
			sWeaponName[commentstart] = 0;

		// get rid of pesky whitespace
		TrimString(sWeaponName);

		g_sRestrictedWeapons[g_iRestrictedWeapons] = sWeaponName;
		g_iRestrictedWeapons++;
	}

	delete file;
}
