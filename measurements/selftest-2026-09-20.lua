
DynamicAmbianceDB = {
["selftest"] = {
["blocked"] = {
},
["finished"] = true,
["cvars"] = {
["brightness"] = {
["readOnly"] = false,
["restored"] = 50,
["secure"] = false,
["name"] = "Brightness",
["locked"] = false,
["value"] = 50,
["default"] = "50.000000",
["wrote"] = 57,
["readBack"] = 57,
},
["contrast"] = {
["readOnly"] = false,
["restored"] = 50,
["secure"] = false,
["name"] = "Contrast",
["locked"] = false,
["value"] = 50,
["default"] = "50.000000",
["wrote"] = 57,
["readBack"] = 57,
},
},
["checks"] = {
{
["name"] = "client",
["detail"] = "1.60.1 build 69913 toc 16001",
},
{
["name"] = "frame rate",
["detail"] = "363 fps",
},
{
["name"] = "combat",
["detail"] = "nil",
},
{
["ok"] = true,
["name"] = "Contrast is writable",
["detail"] = "locked=false secure=false readonly=false",
},
{
["ok"] = true,
["name"] = "Contrast readback",
["detail"] = "wrote 57.00, read 57",
},
{
["ok"] = true,
["name"] = "Contrast restore",
["detail"] = "back to 50",
},
{
["ok"] = true,
["name"] = "Brightness is writable",
["detail"] = "locked=false secure=false readonly=false",
},
{
["ok"] = true,
["name"] = "Brightness readback",
["detail"] = "wrote 57.00, read 57",
},
{
["ok"] = true,
["name"] = "Brightness restore",
["detail"] = "back to 50",
},
{
["ok"] = true,
["name"] = "zone name",
["detail"] = "Elwynn Forest",
},
{
["name"] = "subzone",
["detail"] = "Northshire Valley",
},
{
["ok"] = true,
["name"] = "map id",
["detail"] = "1429",
},
{
["ok"] = true,
["name"] = "position read",
["detail"] = "0.4779, 0.4377",
},
{
["name"] = "target here",
["detail"] = "c=50.0 b=50.0",
},
{
["ok"] = true,
["name"] = "sweep ran",
["detail"] = "809 frames in 3.00s (270 fps), 809 writes",
},
{
["ok"] = true,
["name"] = "sweep wrote every step it should have",
["detail"] = "809 writes over 3.0s",
},
{
["ok"] = true,
["name"] = "no hitch during the sweep",
["detail"] = "gap min 2 / p50 4 / p99 5 / max 10 ms",
},
{
["ok"] = true,
["name"] = "restored after the sweep",
["detail"] = "b=50 c=50",
},
{
["ok"] = true,
["name"] = "client refused nothing",
["detail"] = "no ADDON_ACTION_BLOCKED/FORBIDDEN",
},
},
["env"] = {
["fps"] = 362.5377502441406,
["build"] = {
["toc"] = "16001",
["version"] = "1.60.1",
["build"] = "69913",
},
},
["sweep"] = {
["seconds"] = 3.000000113854185,
["to"] = {
["brightness"] = 70,
["contrast"] = 70,
},
["gapP50Ms"] = 4.000000189989805,
["frames"] = 809,
["fps"] = 269.6666564324409,
["gapMaxMs"] = 10.00000070780516,
["readBackC"] = 50,
["from"] = {
["brightness"] = 50,
["contrast"] = 50,
},
["readBackB"] = 50,
["writes"] = 809,
["gapMinMs"] = 2.000000094994903,
["gapP99Ms"] = 5.000000353902578,
},
["where"] = {
["map"] = 1429,
["x"] = 0.4779279232025147,
["zone"] = "Elwynn Forest",
["subzone"] = "Northshire Valley",
["mode"] = "auto",
["target"] = {
["brightness"] = 50,
["contrast"] = 50,
},
["y"] = 0.4376526474952698,
},
["when"] = "2026-09-20 12:02:59",
},
}
