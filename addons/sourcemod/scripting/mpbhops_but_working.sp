
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin myinfo = 
{
	name = "MPBHOPS, BUT WORKING",
	author = "rtldg, DaFox",
	description = "Prevents (oldschool) bhop plattform from moving down. But actually working.",
	version = "1.0",
	url = "https://github.com/rtldg/mpbhops_but_working"
};

#define SF_DOOR_PTOUCH       1024   // player touch opens
#define SF_DOOR_LOCKED       2048   // Door is initially locked
#define SF_DOOR_SILENT       4096   // Door plays no audible sound, and does not alert NPCs when opened
#define SF_DOOR_IGNORE_USE   32768  // Completely ignores player +use commands.
#define DOOR_FLAGS (SF_DOOR_PTOUCH | SF_DOOR_LOCKED | SF_DOOR_SILENT | SF_DOOR_IGNORE_USE)

#define SF_BUTTON_DONTMOVE          1
#define SF_BUTTON_TOUCH_ACTIVATES   256 // Button fires when touched.
#define BUTTON_FLAGS (SF_BUTTON_DONTMOVE | SF_BUTTON_TOUCH_ACTIVATES)

#define HACKY_TELEPORTER_ENT_PROP "m_flElasticity" //"m_flWaveHeight"
#define HACKY_TELEPORTER_ENT_PROP_DEFAULT 1.0 //0.0

#define TELEPORT_DELAY       0.06 // Max time a player can touch a bhop platform
#define PLATTFORM_COOLDOWN   1.10 // Reset a bhop platform anyway until this cooldown lifts

bool gB_Late;
Handle gH_Touch;
int gI_LastBlock[MAXPLAYERS+1];
float gF_PunishTime[MAXPLAYERS+1];
float gF_LastJump[MAXPLAYERS+1];
int gI_CurrentTraceEntity;
int gI_LastGroundEntity[MAXPLAYERS+1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	gB_Late = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	Handle hGameConf = LoadGameConfigFile("sdkhooks.games");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "Touch");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	gH_Touch = EndPrepSDKCall();
	CloseHandle(hGameConf);

	HookEvent("player_jump", Player_Jump);

	if (gB_Late)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, "func_door")) != -1)
			HookBlock(ent, false);

		ent = -1;
		while ((ent = FindEntityByClassname(ent, "func_button")) != -1)
			HookBlock(ent, true);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "func_door"))
	{
		RequestFrame(Frame_HookDoor, EntIndexToEntRef(entity));
	}
	else if (StrEqual(classname, "func_button"))
	{
		RequestFrame(Frame_HookButton, EntIndexToEntRef(entity));
	}
}

public void OnClientConnected(int client)
{
	gI_LastBlock[client] = -1;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_GroundEntChangedPost, Hook_GroundEntChangedPost);
}

public void Hook_GroundEntChangedPost(int client)
{
	int ground = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity");
	gI_LastGroundEntity[client] = (ground == -1) ? -1 : EntIndexToEntRef(ground);
}

void Player_Jump(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	gF_LastJump[client] = GetGameTime();

	int lastGround = EntRefToEntIndex(gI_LastGroundEntity[client]);

	if (lastGround <= MaxClients)
		return;

	char classname[20];
	GetEntityClassname(lastGround, classname, sizeof(classname));

	if (!StrEqual(classname, "func_door") && !StrEqual(classname, "func_button"))
		return;

	// only booster blocks are -1
	if (view_as<int>(GetEntPropFloat(lastGround, Prop_Data, HACKY_TELEPORTER_ENT_PROP)) != -1)
		return;

	float vel[3];
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", vel);
	vel[2] += GetEntPropFloat(lastGround, Prop_Data, "m_flSpeed");
	SetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", vel);
}

Action Block_Touch_Teleport(int block, int client)
{
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;

	float time = GetGameTime();
	float diff = time - gF_PunishTime[client];

	if(gI_LastBlock[client] != block || diff > PLATTFORM_COOLDOWN)
	{
		gI_LastBlock[client] = block;
		gF_PunishTime[client] = time + TELEPORT_DELAY;
	}
	else if(diff > TELEPORT_DELAY)
	{
		if(time > (PLATTFORM_COOLDOWN + TELEPORT_DELAY))
		{
			int tele = EntRefToEntIndex(view_as<int>(GetEntPropFloat(block, Prop_Data, HACKY_TELEPORTER_ENT_PROP)));

			if (tele > 0)
			{
				gI_LastBlock[client] = -1;
				SDKCall(gH_Touch, tele, client);
			}
		}
	}

	return Plugin_Handled;
}

bool TeleportFilter(int entity)
{
	char classname[20];
	GetEntityClassname(entity, classname, sizeof(classname));

	if (StrEqual(classname, "trigger_teleport"))
	{
		//TR_ClipCurrentRayToEntity(MASK_ALL, entity);
		gI_CurrentTraceEntity = entity;
		return false;
	}

	return true;
}

void Frame_HookDoor(int ref)
{
	int ent = EntRefToEntIndex(ref);
	if (IsValidEntity(ent))
		HookBlock(ent, false);
}

void Frame_HookButton(int ref)
{
	int ent = EntRefToEntIndex(ref);
	if (IsValidEntity(ent))
		HookBlock(ent, true);
}

void HookBlock(int ent, bool isButton)
{
	if (GetEntProp(ent, Prop_Data, "m_spawnflags") & (isButton ? SF_BUTTON_TOUCH_ACTIVATES : SF_DOOR_PTOUCH) == 0)
		return;

	float hackyProp = GetEntPropFloat(ent, Prop_Data, HACKY_TELEPORTER_ENT_PROP);

	if (hackyProp == HACKY_TELEPORTER_ENT_PROP_DEFAULT)
	{
		float startpos[3], endpos[3];
		GetEntPropVector(ent, Prop_Data, "m_vecPosition1", startpos);
		GetEntPropVector(ent, Prop_Data, "m_vecPosition2", endpos);

		if (startpos[2] > endpos[2])
		{
			float mins[3], maxs[3];
			GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);

			float tracestartpos[3];
			tracestartpos[0] = startpos[0] + (mins[0] + maxs[0]) * 0.5;
			tracestartpos[1] = startpos[1] + (mins[1] + maxs[1]) * 0.5;
			tracestartpos[2] = startpos[2] + maxs[2];
			endpos[2] += maxs[2];

			gI_CurrentTraceEntity = 0;
			TR_EnumerateEntities(tracestartpos, endpos, PARTITION_TRIGGER_EDICTS, RayType_EndPoint, TeleportFilter);

			if (gI_CurrentTraceEntity <= MaxClients)
				return;

			hackyProp = view_as<float>(EntIndexToEntRef(gI_CurrentTraceEntity));
		}
		else if (startpos[2] < endpos[2])
		{
			float wait = GetEntPropFloat(ent, Prop_Data, "m_flWait");

			if (wait <= 0.0)
				return;

			hackyProp = view_as<float>(-1);
		}

		//LogToFile("test.log", "%d %f %f %f %f", ent, hackyProp, startpos[0], startpos[1], startpos[2]);

		SetEntPropFloat(ent, Prop_Data, HACKY_TELEPORTER_ENT_PROP, hackyProp);
		SetEntPropVector(ent, Prop_Data, "m_vecPosition2", startpos);
		//SetEntPropFloat(ent, Prop_Data, "m_flSpeed", 0.0);
		SetEntProp(ent, Prop_Data, "m_spawnflags", isButton ? BUTTON_FLAGS : DOOR_FLAGS);

		if (!isButton)
			AcceptEntityInput(ent, "Lock");
	}

	if (view_as<int>(hackyProp) == -1) // booster blocks
	{
		//SDKHook(ent, SDKHook_Touch, Block_Touch_Boost);
	}
	else
	{
		SDKHook(ent, SDKHook_Touch, Block_Touch_Teleport);
	}
}
