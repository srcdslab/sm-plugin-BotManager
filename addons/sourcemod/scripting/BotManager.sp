#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smlib>

#pragma semicolon 1
#pragma newdecls required

#define BOT_NAME_FILE			"configs/botnames.cfg"
#define BOT_RESTRICTIONS_FILE	"configs/botrestrictions.cfg"

// this array will store the names loaded
ArrayList bot_names;

// this array will have a list of indexes to
// bot_names, use these in order
ArrayList name_redirects;

char g_sRestrictedWeapons[64][64];
int g_iRestrictedWeapons = 0;

// this is the next index to use into name_redirects
// update this each time you use a name
int next_index;

// Entities
int g_iPlayerResourceEntity	= -1;

// Offsets
int g_iPing				= -1;

// Timers
Handle g_hPingTimer = null;

// ConVars
ConVar g_hMinPing	= null;
ConVar g_hMaxPing	= null;
ConVar g_hInterval	= null;
ConVar g_hPrefix	= null;
ConVar g_hRandom	= null;
ConVar g_hAnnounce	= null;
ConVar g_hSuppress	= null;

public Plugin myinfo =
{
	name = "BotManager",
	author = "Rakeri, Knagg0, maxime1907",
	description = "Manage bot's name, ping and weapon restictions",
	version = "1.2",
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
	if (g_hPingTimer != null)
	{
		delete g_hPingTimer;
	}
}

public void OnConfigsExecuted()
{
	g_hPingTimer = CreateTimer(g_hInterval.FloatValue, ChangeBotsPing, _, TIMER_REPEAT);
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
public Action Command_Reload(int args)
{
	LoadWeaponRestrictions();
	ReloadNames();
	GenerateRedirects();
	PrintToServer("[BotManager] Loaded %i names and restricted.", bot_names.Length);
	return Plugin_Continue;
}

// handle client connection, to change the names...
public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	int loaded_names = bot_names.Length;

	if (IsFakeClient(client) && !IsClientSourceTV(client) && loaded_names != 0)
	{
		// we got a bot, here, boss
		
		char newname[MAX_NAME_LENGTH];
		bot_names.GetString(name_redirects.Get(next_index), newname, MAX_NAME_LENGTH);

		next_index++;
		if (next_index > loaded_names - 1)
		{
			next_index = 0;
		}
		
		SetClientInfo(client, "name", newname);
		if (g_hAnnounce.BoolValue)
		{
			PrintToChatAll("[botnames] Bot %s created.", newname);
			PrintToServer("[botnames] Bot %s created.", newname);
		}
	}
	return true;
}

// handle "SayText2" usermessages, including name change notifies!
public Action UserMessage_SayText2(UserMsg msg_id, Handle bf, const int[] players, int playersNum, bool reliable, bool init)
{
	if (!g_hSuppress.BoolValue)
	{
		return Plugin_Continue;
	}

	char message[256];

	BfRead bfRead = UserMessageToBfRead(bf);
	bfRead.ReadShort(); // team color

	bfRead.ReadString(message, sizeof(message));
	// check for Name_Change, not #TF_Name_Change (compatibility?)
	if (StrContains(message, "Name_Change") != -1)
	{
		bfRead.ReadString(message, sizeof(message)); // original
		bfRead.ReadString(message, sizeof(message)); // new
		if (bot_names.FindString(message) != -1)
		{
			// 'tis a bot!
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

// handle player team change, to supress bot messages
public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hSuppress.BoolValue)
	{
		return Plugin_Continue;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client == 0)
	{
		// weird error, ignore
		return Plugin_Continue;
	}
	if (IsFakeClient(client) && !IsClientSourceTV(client))
	{
		// fake client == bot
		event.SetBool("silent", true);
		return Plugin_Changed;
	}

	return Plugin_Continue;
}

// handle player connect, to supress bot messages
public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hSuppress.BoolValue)
	{
		return Plugin_Continue;
	}

	char networkID[32];
	event.GetString("networkid", networkID, sizeof(networkID));

	if(!dontBroadcast && StrEqual(networkID, "BOT"))
	{
		// we got a bot connectin', resend event as no-broadcast
		char clientName[MAX_NAME_LENGTH], address[32];
		event.GetString("name", clientName, sizeof(clientName));
		event.GetString("address", address, sizeof(address));

		Event newEvent = CreateEvent("player_connect", true);
		newEvent.SetString("name", clientName);
		newEvent.SetInt("index", event.GetInt("index"));
		newEvent.SetInt("userid", event.GetInt("userid"));
		newEvent.SetString("networkid", networkID);
		newEvent.SetString("address", address);

		newEvent.Fire(true);

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

stock Action ChangeBotsPing(Handle timer)
{
	if (g_iPlayerResourceEntity == -1 || g_iPing == -1)
		return Plugin_Continue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if(!IsValidEdict(i) || !IsClientInGame(i) || !IsFakeClient(i) || IsClientSourceTV(i))
			continue;

		SetEntData(g_iPlayerResourceEntity, g_iPing + (i * 4), GetRandomInt(g_hMinPing.IntValue, g_hMaxPing.IntValue));
	}
	return Plugin_Continue;
}

// a function to generate name_redirects
stock void GenerateRedirects()
{
	int loaded_names = bot_names.Length;

	if (name_redirects != null)
	{
		name_redirects.Resize(loaded_names);
	} else {
		name_redirects = new ArrayList(1, loaded_names);
	}

	for (int i = 0; i < loaded_names; i++)
	{
		name_redirects.Set(i, i);
		
		// nothing to do random-wise if i == 0
		if (i == 0)
		{
			continue;
		}

		// now to introduce some chaos
		if (g_hRandom.BoolValue)
		{
			name_redirects.SwapAt(GetRandomInt(0, i - 1), i);
		}
	}
}

// a function to load data into bot_names
stock void ReloadNames()
{
	next_index = 0;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), BOT_NAME_FILE);
	
	if (bot_names != null)
	{
		bot_names.Clear();
	} else {
		bot_names = new ArrayList(MAX_NAME_LENGTH);
	}
	
	File file = OpenFile(path, "r");
	if (file == null)
	{
		//PrintToServer("bot name file unopened");
		return;
	}
	
	// this LENGTH*3 is sort of a hack
	// don't make long lines, people!
	char newname[MAX_NAME_LENGTH*3];
	char formedname[MAX_NAME_LENGTH];
	char prefix[MAX_NAME_LENGTH];

	g_hPrefix.GetString(prefix, MAX_NAME_LENGTH);

	while (file.EndOfFile() == false)
	{
		if (file.ReadLine(newname, sizeof(newname)) == false)
		{
			break;
		}
		
		// trim off comments starting with // or #
		int commentstart;
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
		
		int length = strlen(newname);
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
		bot_names.PushString(formedname);
	}
	
	delete file;
}

stock void LoadWeaponRestrictions()
{
	g_iRestrictedWeapons = 0;
	for (int i = 0; i < sizeof(g_sRestrictedWeapons); i++)
		g_sRestrictedWeapons[i] = "";

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), BOT_RESTRICTIONS_FILE);

	File file = OpenFile(path, "r");
	if (file == null)
	{
		LogError("Couldnt find %s", BOT_RESTRICTIONS_FILE);
		return;
	}

	char sWeaponName[64] = "";
	while (!file.EndOfFile())
	{
		if (!file.ReadLine(sWeaponName, sizeof(sWeaponName)))
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
