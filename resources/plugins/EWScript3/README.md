# EW Script 3.0: EA-18G AEA (Timberwolf)

Retribution plugin for _Timberwolf_'s EA-18G Airborne Electronic Attack script:
<https://forum.dcs.world/topic/385186-ea-18g-style-electronic-warfare-script-v2/>

It simulates the JMRS jamming system (multiple radar groups jammed at once, ECCM tiers, burn-through,
JMRS heat and overheat lockout), the ALQ-218 RWR picture, disruption of radar-guided missiles and short
radar "blinks" on enemy AI fighters.

> **Do not enable this together with EW Script 2.1 (`ewrj`).** Both scripts act on SAM ROE and incoming
> missiles independently. If both are enabled, Retribution logs a warning and DCS shows one at mission start.

## Which aircraft are jammers

Only aircraft carrying **offensive (stand-off / escort) jamming pods** are registered:

| Pods fitted | Script loadout | AI max targets |
|---|---|---|
| 1x ALQ-99 | `1xALQ99` | 2 |
| 2x ALQ-99 | `2xALQ99` | 4 |
| 3+ ALQ-99 (EA-18G full, EA-6B) | `3xALQ99` | 6 |
| 2x ALQ-249 | `2xALQ249` | 4 |
| 2x ALQ-249 + ALQ-99 | `2xALQ249_1xALQ99` | 6 |
| 1x ALQ-249 (+ ALQ-99) | nearest of the above | by pod count |
| `has_built_in_jamming` (e.g. E-7A), no pods | `2xALQ99` | 4 |

Self-protection pods (ALQ-131, ALQ-184, ALQ-164, MPS-410, L005, Sky Shadow, BARAX, ...) are not AEA jammers
and are not handled by this plugin. EW Script 2.1 covers them.

## Players

Player slots with a jamming loadout get the **F10 > AEA MENU** automatically, with the LOADOUT already set to
the pods actually fitted. Use JMRS > XMIT/OFF, TJSR/RWR, PRIORITIES (power, band, max targets, direction) and
SCRIPT > MESSAGES as described in the forum thread. Units named `[EA-18G]...` in hand-made missions still
work.

## AI behaviour

This follows how real EA flights work: escort/stand-off jamming that is cued by the ALQ-218, and kept short
so the jammer is not giving away its position (home-on-jam) or overheating the pods.

1. **Mission window.** An AI jammer is *armed* at its JOIN waypoint (or RACETRACK START) and *disarmed* at
   SPLIT (or RACETRACK END). Flights without those waypoints are always armed.
2. **Reactive XMIT.** While armed, the jammer transmits only when:
   * **Lit up:** an enemy radar it can hear is tracking a friendly aircraft within the protect radius (the
     jammer itself or the package it is escorting), or
   * **Under threat:** an enemy active or semi-active radar missile is in flight against a protected
     aircraft, or
   * (optional) an enemy search/EW radar is emitting (`ai_jam_search`).
3. **Hold.** After the last threat it keeps transmitting for `ai_hold_sec`, then goes quiet.
4. **Power.** It runs at NORM, goes to HIGH while a missile threat is live, and drops to LOW at 70 % JMRS heat.
   The script's overheat lockout (120 s) still applies.
5. Band BOTH, direction AUTO, max targets from the pod count.

## Options

| Option | Default | Notes |
|---|---|---|
| Player AEA menu | on | |
| Enable AI jammers | on | |
| AI: only jam inside mission window | on | off = reactive at any time |
| AI: pre-emptively jam active search/EW radars | off | on = XMIT as soon as an enemy search radar is heard |
| Protect friendly aircraft within (NM) | 25 | escort coverage for lit-up checks and missile disruption |
| AI: keep transmitting after last threat (s) | 30 | |
| Jamming range multiplier | 0.7 | upstream value |
| Missile disruption chance (0-1) | 0.5 | per missile, rolled once |
| Missile disruption range (NM) | 10 | from the jammer or from the targeted friendly |
| Jam enemy AI aircraft radars | on | brief WEAPON HOLD on radar-equipped enemy AI fighters |
| DEBUG - write to dcs.log | off | |
| DEBUG - in-game messages | off | sent to the jammer's coalition |
| DEBUG - verbose | off | scans, scores, ECCM rolls, heat (needs DEBUG - dcs.log for the log) |

## Debugging

Enable **DEBUG - write to dcs.log**, fly the mission and search `Saved Games\DCS\Logs\dcs.log` for `[EWS3]`:

```
[EWS3] Growler-1: registered (AI) loadout=3xALQ99 maxTargets=6 gated=true
[EWS3] Growler-1: ARMED (mission window open)
[EWS3] Growler-1: THREAT: LIT UP by SA-11 SA-11 Buk LN 9A310M1 (SA-11 site) tracking Strike-1
[EWS3] Growler-1: XMIT ON - LIT UP by SA-11 ... (heat 0%)
[EWS3] Growler-1: JAM 1/1 groups in range [SA-11 site] pwr=NORM heat=4%
[EWS3] Growler-1: MSL ROLL SA9M317 -> Strike-1 rng=3.2NM roll=0.41 thr=0.50
[EWS3] Growler-1: XMIT OFF - no threat for 30s (heat 12%)
[EWS3] Growler-1: DISARMED (mission window closed)
```

AI jammers also log a status line every 30 s. Script errors are always logged as `[EWS3] update error`.

## Changes from the upstream script

See the header of `Growler_AEA_with_MRAD.lua`. In short: only enemy emitters, aircraft and missiles are
affected; only active and semi-active radar missiles can be disrupted (not anti-radiation, IR or bombs); band
bias now works; several undefined variables were fixed; and a SAM is only released from WEAPON HOLD when its
latest suppression has expired.

Note: suppression works by toggling the SAM's ROE. Other scripts that manage SAM ROE (for example Skynet IADS)
may set it back on their own schedule.
