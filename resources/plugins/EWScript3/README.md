# EW Script 3.0: EA-18G AEA (Timberwolf)

Retribution plugin for _Timberwolf_'s EA-18G Airborne Electronic Attack script:
<https://forum.dcs.world/topic/385186-ea-18g-style-electronic-warfare-script-v2/>

It simulates the JMRS jamming system (multiple radar groups jammed at once, ECCM tiers, burn-through,
JMRS heat and overheat lockout), the ALQ-218 RWR picture, disruption of radar-guided missiles and short
radar "blinks" on enemy AI fighters.

> **Do not enable this together with EW Script 2.1 (`ewrj`).** Both scripts act on SAM ROE and incoming
> missiles independently. If both are enabled, Retribution logs a warning and DCS shows one at mission start.

## Which aircraft are jammers

Aircraft carrying **offensive (stand-off / escort) jamming pods** are registered as AEA jammers:

| Pods fitted | Script loadout | Range factor | AI max targets (player menu max) |
|---|---|---|---|
| 1x ALQ-99 | `1xALQ99` | 0.85 | 2 (6) |
| 2x ALQ-99 | `2xALQ99` | 1.00 | 4 (6) |
| 3+ ALQ-99 (EA-18G full, EA-6B) | `3xALQ99` | 1.10 | 6 (6) |
| 1x ALQ-249 | `1xALQ249` | 1.00 | 4 (6) |
| 1x ALQ-249 + 1x ALQ-99 | `1xALQ249_1xALQ99` | 1.10 | 4 (6) |
| 1x ALQ-249 + 2x ALQ-99 | `1xALQ249_2xALQ99` | 1.15 | 6 (9) |
| 2x ALQ-249 | `2xALQ249` | 1.15 | 6 (9) |
| 2x ALQ-249 + ALQ-99 | `2xALQ249_1xALQ99` | 1.20 | 9 (9) |
| `has_built_in_jamming` (e.g. E-7A), no pods | `2xALQ99` | 1.00 | 4 |

Aircraft with **self-protection pods** or internal ECM are registered as self-protection jammers (see below).

### ALQ-249 Mid Band (NGJ-MB)

The NGJ-MB is a GaN AESA that steers several independent beams and has much higher effective radiated power
than the ALQ-99. In the script that means:

* **More targets.** NGJ loadouts jam up to 9 groups at once. Spreading over more beams still shortens each
  hold (the upstream 9-target modifier), and 9 targets heats the JMRS 20 % faster.
* **Range and heat.** It has a longer jamming range, runs cooler, and has a 60 NM (not 40 NM) anti-ship range.
  These are upstream values.
* **Mid band only.** The NGJ-MB covers the S/C band. Against S-band (search / acquisition) radars it has
  −0.04 ECCM resistance per pod (max −0.08), +10 % hold and 20 % shorter burn-through. X-band fire-control
  radars are still the ALQ-99 high-band pods' job: a loadout with no ALQ-99 is slightly weaker against them
  (+0.05 resistance).

## Self-protection jammers

Defensive ECM pods (`WeaponType.JAMMER`) protect **only the aircraft carrying them**:
ALQ-131, ALQ-184, ALQ-164, MPS-410, L005, L175V, RKL609, Sky Shadow, BARAX and SPS-141.
Aircraft with internal ECM (`has_built_in_ecm`: F/A-18C/E/F, F-35) are included too unless you switch that
option off. Self-protection runs automatically, for AI and players, with no menu and no mission window, like
a real DECM in AUTO. It has no heat model.

* **Track break.** When an enemy SAM/ship radar or enemy AI fighter is *tracking this aircraft*, deception
  jamming may break the track for a short WEAPON HOLD (2–6 s, then an 8 s cooldown per radar). Compared with
  the AEA jammer it has less power: more ECCM resistance, shorter holds, and burn-through 1.6x further out.
  Inside burn-through range it does nothing.
* **Missile defeat.** Each enemy active or semi-active radar missile aimed at this aircraft gets one roll once
  it is within the defeat range (default 5 NM). Missiles aimed at other aircraft are ignored.
* **Generation.** This comes from the pod's introduction year:

| Generation | Pods (year) | ECCM resist | Hold | Missile chance |
|---|---|---|---|---|
| 1 (before 1985) | ALQ-131, Sky Shadow, BARAX, SPS-141 | +0.20 | x0.5 | x0.6 |
| 2 (1985–1995) | ALQ-184, L005, L175V, RKL609, MPS-410 | +0.12 | x0.6 | x1.0 |
| 3 (after 1995) | ALQ-164, internal ECM | +0.05 | x0.7 | x1.4 |

DCS limitation: SAM ROE is set per group. A track break therefore also pauses that SAM group's other
engagements for those few seconds.

AEA jammers are never also registered as self-protection jammers, because their own jamming already covers
them. DCS's built-in AI ECM behaviour (`ECM using`) is unchanged.

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
| Self-protection jammers | on | ECM pods protect their carrier |
| Self-protection: include internal ECM | on | F/A-18C/E/F, F-35 |
| Self-protection for player aircraft | on | |
| Self-protection missile defeat chance | 0.25 | scaled by generation (x0.6 / x1.0 / x1.4) |
| Self-protection missile defeat range (NM) | 5 | from the carrier |
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

Self-protection jammers log lines like:

```
[EWS3] Viper-1: registered self-protection (AI) pod=AN/ALQ-184 ECM gen=2
[EWS3] Viper-1: SPJ ON - tracked by SA-11 Buk LN 9A310M1 (SA-11 site)
[EWS3] Viper-1: SPJ TRACK BREAK SA-11 Buk LN 9A310M1 (SA-11 site) tier=2 hold=2.3s rng=40.1NM
[EWS3] Viper-1: SPJ MSL ROLL SA9M317 (from SA-11 Buk LN 9A310M1) rng=4.2NM roll=0.61 thr=0.25 -> not defeated
[EWS3] Viper-1: SPJ OFF - no longer tracked
```

AI jammers also log a status line every 30 s. Script errors are always logged as `[EWS3] update error`.

## Changes from the upstream script

See the header of `Growler_AEA_with_MRAD.lua`. In short: only enemy emitters, aircraft and missiles are
affected; only active and semi-active radar missiles can be disrupted (not anti-radiation, IR or bombs); band
bias now works; several undefined variables were fixed; and a SAM is only released from WEAPON HOLD when its
latest suppression has expired.

Note: suppression works by toggling the SAM's ROE. Other scripts that manage SAM ROE (for example Skynet IADS)
may set it back on their own schedule.
