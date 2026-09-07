//! Headless simulation playtests, separate from real browser/controller tests.
#[allow(dead_code)]
#[path = "../src/rules.rs"]
mod rules;
use rules::{BombState, Game, Phase, Team};

fn main() {
    let mut records = Vec::new();
    let (mut plants, mut defuses, mut repositions, mut investigations) = (0, 0, 0, 0);
    for seed in 1..=24u32 {
        let mut game = Game::seeded(seed * 7919);
        let observing = seed % 2 == 0;
        let mut seconds = 0.;
        let mut previous_bomb = game.bomb.state;
        let mut paths = std::collections::VecDeque::new();
        for _ in 0..26000 {
            if observing {
                game.health = 0.;
            } else if game.phase == Phase::Live && game.health > 0. {
                // A simple test player follows a lane and only shoots visible opponents.
                if paths.is_empty() {
                    paths = game
                        .map
                        .path(game.pos, rules::SITES[((seed + game.round) % 2) as usize]);
                }
                if let Some(next) = paths.front().copied() {
                    let d = game.pos.distance(next);
                    if d < 0.16 {
                        paths.pop_front();
                    } else {
                        let (dx, dz) = (
                            (next.x - game.pos.x) / d * 0.12,
                            (next.z - game.pos.z) / d * 0.12,
                        );
                        game.map.move_by(&mut game.pos, dx, dz);
                    }
                }
                let target = game
                    .bots
                    .iter()
                    .filter(|b| {
                        b.team == Team::T && b.health > 0. && game.map.visible(game.pos, b.pos)
                    })
                    .min_by(|a, b| {
                        game.pos
                            .distance(a.pos)
                            .total_cmp(&game.pos.distance(b.pos))
                    })
                    .map(|b| b.pos);
                if let Some(p) = target {
                    let eye = game.map.elevation(game.pos.x, game.pos.z) + 1.62;
                    game.fire(
                        [game.pos.x, eye, game.pos.z],
                        [
                            p.x - game.pos.x,
                            game.map.elevation(p.x, p.z) + 1.1 - eye,
                            p.z - game.pos.z,
                        ],
                        true,
                        false,
                    );
                }
                if game.ammo == 0 {
                    game.start_reload();
                }
            } else {
                paths.clear();
            }
            game.tick(0.05, !observing && game.bomb.pos.distance(game.pos) < 1.5);
            seconds += 0.05;
            for bot in &game.bots {
                assert!(
                    game.map.can_stand(bot.pos),
                    "Seed {seed}: actor in solid geometry at {:?}",
                    bot.pos
                );
                assert!(bot.yaw.is_finite() && bot.health.is_finite());
                if bot.intent == rules::ai::Intent::Reposition {
                    repositions += 1;
                }
                if bot.intent == rules::ai::Intent::Investigate {
                    investigations += 1;
                }
            }
            if game.bomb.state != previous_bomb {
                if game.bomb.state == BombState::Planted {
                    plants += 1;
                }
                if game.bomb.state == BombState::Defused {
                    defuses += 1;
                }
                previous_bomb = game.bomb.state;
            }
            if game.phase == Phase::Finished {
                break;
            }
        }
        assert_eq!(
            game.phase,
            Phase::Finished,
            "Seed {seed}: match failed to terminate"
        );
        let kills: u32 = game.bots.iter().map(|b| b.kills).sum();
        assert!(kills > 0, "Seed {seed}: bots never fought");
        let mode = if observing {
            "spectator"
        } else {
            "scripted player"
        };
        println!(
            "seed {:6} | {:15} | CT {}:{} T | {} rounds | {:5.0}s | {} bot kills",
            game.seed, mode, game.scores[0], game.scores[1], game.round, seconds, kills
        );
        records.push(format!("{{\"seed\":{},\"mode\":\"{}\",\"ct\":{},\"t\":{},\"rounds\":{},\"seconds\":{:.1},\"botKills\":{}}}", game.seed, mode, game.scores[0], game.scores[1], game.round, seconds, kills));
    }
    assert!(plants > 0 && defuses > 0 && repositions > 0 && investigations > 0);
    let report = format!(
        "{{\"matches\":[{}],\"plants\":{},\"defuses\":{},\"repositionTicks\":{},\"investigateTicks\":{},\"note\":\"Deterministic simulation playtests; not GPU, browser-input, or human difficulty ratings.\"}}",
        records.join(","),
        plants,
        defuses,
        repositions,
        investigations
    );
    std::fs::create_dir_all("artifacts").unwrap();
    std::fs::write("artifacts/ai-playtest.json", report).unwrap();
    println!(
        "24 complete matches; {plants} plants, {defuses} defuses. Collision/finite-state checks passed. Report: artifacts/ai-playtest.json"
    );
}
