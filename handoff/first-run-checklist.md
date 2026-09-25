# First run in game — acceptance checklist

The headless suite (`luajit tests/run.lua`) covers the addon's own logic against a stand-in
client. It cannot tell you the screen changed. This is the list that can.

Already done: `scripts/install-addon.ps1` has copied the addon to
`F:\World of Warcraft\_classic_beta_\Interface\AddOns\DynamicAmbiance`.

**Order matters.** This client writes SavedVariables and never reads them back, and a reload
*replaces* the file rather than merging into it — so run the commands first and reload after.
A reload before running anything writes an empty table over the last session's results.

---

## 1. It loads

Log in, or `/reload` if you are already in.

Expect a line: `Ambiance loaded. 2 zones configured, baseline c=50 b=50. Client is at c=NN b=NN.`

- No line → the addon is not enabled. Escape → AddOns, tick **Dynamic Ambiance**, `/reload`.
- A Lua error → copy it verbatim; that is the interesting outcome.
- **Write down the `c=NN b=NN` it reports.** That is your real neutral. If it is not 50/50,
  it goes into `Config.baseline` in `addons/DynamicAmbiance/Config.lua`, or the addon will
  pull your screen to 50/50 every time it has nothing better to do.

## 2. It knows where you are

```
/amb
```

Expect `mode=auto`, your zone and subzone, a current and a target, and what the client
reports. Zone should match the zone name on screen.

## 3. A write actually changes the screen

This is the one measurement that matters, and nothing so far has proven it.

```
/amb selftest
```

It takes about three seconds and **watch the screen while it runs.** It checks the CVars
exist, reads their lock/secure/read-only flags, writes each one and reads it back, sweeps
brightness and contrast 20 points down and back from `OnUpdate`, records the frame gaps,
captures any `ADDON_ACTION_BLOCKED`/`FORBIDDEN` the client fires, and puts everything back
where it found it. Every line comes out `PASS` or `FAIL` in chat and the whole thing is
written to `DynamicAmbianceDB.selftest`, so the result is a record rather than a
recollection — after you `/reload` I can read it myself.

Any `FAIL` is the interesting outcome. Leave it alone and say so.

Then the part no addon can check, which the test asks you in plain words at the end: **did
the screen visibly change during the sweep, smoothly, with no flicker or stutter?**

- Nothing happened, but every line said PASS → the CVar is accepted and ignored. That is a
  finding, and it kills the premise; say so and nothing below matters.
- It changed but in one jump → the ease is not running; `/amb` and check `mode`.
- It stuttered → note the frame rate, and whether `no hitch during the sweep` failed.

For the same thing under your own hands rather than a script:

```
/amb try 100 100
/amb try 0 0
/amb auto
```

## 4. It follows the map

Go to Duskwood if you can get there (the shipped example config covers Duskwood and
Westfall; `/amb config` lists what is loaded). Otherwise pick any zone, stand in it, and:

```
/amb try 70 25
/amb here
```

`/amb here` should print a paste-ready entry naming that zone and subzone. Walk across a
subzone boundary with `/amb debug` on and watch the target change and the current value
chase it rather than snap.

## 5. Combat

Pull something harmless.

Expect `/amb` to say `(frozen: combat)` and the value to stop moving. It should resume when
you drop combat.

Then the open question worth closing while you are there — does a write survive combat at
all? Still in combat:

```
/amb selftest
```

The self test writes directly rather than through the frozen loop, so this is the real
answer: it records `combat = true` alongside the readbacks and any refusal the client fired.
If it comes back clean, set `freezeInCombat = false` in `Config.lua` and the freeze goes
away — and that is a finding for the plugin repo, since nobody has measured it.

Pick something that will not kill you while you read chat.

## 6. On the way out

```
/amb off
```

Expect the screen to ease back to the baseline and a line saying so. Then `/reload`.

After the reload, the captures from `/amb here` are in
`F:\World of Warcraft\_classic_beta_\WTF\Account\<account>\SavedVariables\DynamicAmbiance.lua`
and can be read out of there rather than retyped from the chat log.

---

## What to report

Steps 1, 3 and 5 are the ones that decide whether this works. For each: what you expected,
what happened, and the exact text of anything that looked like an error.
