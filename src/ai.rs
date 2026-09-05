//! Small tactical decisions, driven only by sight, recent contacts and gunfire.
//! No renderer dependencies: scenarios and complete matches run in seconds.
use super::*;
use std::f32::consts::{PI, TAU};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Intent {
    Advance,
    Hold,
    Engage,
    Reposition,
    Investigate,
    Retrieve,
    Plant,
    Defuse,
    Cover,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn arena() -> Game {
        let mut g = Game::seeded(731);
        g.phase = Phase::Live;
        g.map.tiles = [[0; W]; H];
        g.map.heights = [[0.; W + 1]; H + 1];
        g.health = 0.;
        for b in &mut g.bots {
            b.health = 0.;
        }
        g.bots[0].health = 100.;
        g.bots[0].pos = Point::new(20., 20.);
        g.bots[0].yaw = PI;
        g.bots[4].health = 100.;
        g.bots[4].pos = Point::new(20., 28.);
        g.bots[4].yaw = 0.;
        g
    }
    #[test]
    fn unseen_enemies_are_not_acquired_and_sound_is_only_a_contact() {
        let mut g = arena();
        for x in 16..25 {
            g.map.tiles[24][x] = 1;
        }
        g.plan_bot(0);
        assert_eq!(g.bots[0].target, None);
        assert!(g.bots[0].contact.is_none());
        g.hear_shot(Team::T, g.bots[4].pos);
        g.plan_bot(0);
        assert_eq!(g.bots[0].target, None);
        assert_eq!(g.bots[0].intent, Intent::Investigate);
        assert_eq!(g.bots[0].contact.unwrap().pos, Point::new(20., 28.));
    }
    #[test]
    fn last_seen_position_does_not_follow_an_enemy_through_a_wall() {
        let mut g = arena();
        g.plan_bot(0);
        assert_eq!(g.bots[0].target, Some(4));
        let seen = g.bots[0].contact.unwrap().pos;
        for x in 16..25 {
            g.map.tiles[24][x] = 1;
        }
        g.bots[4].pos.x += 2.;
        g.tick_bots(0.05);
        assert_eq!(g.bots[0].target, None);
        assert_eq!(g.bots[0].contact.unwrap().pos, seen);
        g.bots[4].health = 0.;
        for _ in 0..100 {
            g.tick_bots(0.05);
        }
        assert!(g.bots[0].contact.is_none(), "Contact must expire");
    }
    #[test]
    fn reaction_time_and_burst_gaps_are_real() {
        let mut g = arena();
        g.bots[0].cooldown = 0.;
        g.plan_bot(0);
        assert!(g.bots[0].cooldown >= 0.45);
        g.bots[0].moving = false;
        let mut gaps = Vec::new();
        for _ in 0..6 {
            g.bot_shoot(0, 4);
            gaps.push(g.bots[0].cooldown);
        }
        assert!(gaps[0] < 0.25 && gaps[1] < 0.25 && gaps[2] >= 1.15);
        assert!(gaps[3] < 0.25 && gaps[4] < 0.25 && gaps[5] >= 1.15);
    }
    #[test]
    fn bot_bullets_respect_cover_and_crossing_teammates() {
        let mut g = arena();
        g.bots[1].health = 100.;
        g.bots[1].pos = Point::new(20., 22.);
        for _ in 0..12 {
            g.bot_shoot(0, 4);
        }
        assert_eq!(g.bots[1].health, 100.);
        assert_eq!(g.bots[4].health, 100.);
        g.bots[1].health = 0.;
        for x in 16..25 {
            g.map.tiles[24][x] = 1;
        }
        for _ in 0..12 {
            g.bot_shoot(0, 4);
        }
        assert_eq!(g.bots[4].health, 100.);
        assert!(g.shots.iter().any(|s| s.impact == Impact::World));
    }
    #[test]
    fn repositioning_chooses_walkable_space_and_wounded_bots_prefer_cover() {
        let mut g = arena();
        for z in 20..25 {
            g.map.tiles[z][22] = 1;
        }
        g.bots[4].pos = Point::new(25., 27.);
        g.bots[0].health = 30.;
        let goal = g.combat_position(0, g.bots[4].pos).unwrap();
        assert!(g.map.walkable_segment(g.bots[0].pos, goal));
        assert!(!g.map.visible(goal, g.bots[4].pos));
        assert!(g.bots[0].pos.distance(goal) > 1.);
    }
    #[test]
    fn squad_has_one_defuser_and_spread_out_cover_positions() {
        let mut g = Game::default();
        g.bomb.state = BombState::Planted;
        g.bomb.pos = SITES[0];
        let roles: Vec<_> = (0..4).map(|i| g.objective(i)).collect();
        assert_eq!(
            roles
                .iter()
                .filter(|(_, role)| *role == Intent::Defuse)
                .count(),
            1
        );
        assert_eq!(
            roles
                .iter()
                .filter(|(_, role)| *role == Intent::Cover)
                .count(),
            3
        );
        for (goal, role) in &roles {
            assert!(g.map.can_stand(*goal));
            if *role == Intent::Cover {
                assert!(goal.distance(g.bomb.pos) > 3.);
            }
        }
        g.bomb.defuser = Some(9);
        assert!((0..4).all(|i| g.objective(i).1 == Intent::Cover));
        g.bomb.state = BombState::Dropped;
        g.bomb.defuser = None;
        assert_eq!(
            (4..9)
                .filter(|i| g.objective(*i).1 == Intent::Retrieve)
                .count(),
            1
        );
    }
    #[test]
    fn wounded_bot_finishes_retreat_and_holds_before_investigating() {
        let mut g = arena();
        for x in 16..25 {
            g.map.tiles[24][x] = 1;
        }
        g.bots[0].health = 30.;
        g.bots[0].contact = Some(Contact {
            pos: g.bots[4].pos,
            ttl: 4.,
        });
        g.bots[0].tactical_goal = Some(Point::new(21.5, 21.5));
        g.bots[0].tactic_time = 2.;
        g.plan_bot(0);
        assert_eq!(g.bots[0].intent, Intent::Reposition);
        assert_eq!(g.bots[0].path.back(), g.bots[0].tactical_goal.as_ref());
        g.bots[0].pos = g.bots[0].tactical_goal.unwrap();
        g.plan_bot(0);
        assert_eq!(g.bots[0].intent, Intent::Hold);
        g.bots[0].tactic_time = 0.;
        g.plan_bot(0);
        assert_eq!(g.bots[0].intent, Intent::Investigate);
    }
    #[test]
    fn active_defuser_keeps_progress_when_a_teammate_crosses_the_bomb() {
        let mut g = arena();
        g.bomb.state = BombState::Planted;
        g.bomb.pos = Point::new(20., 20.);
        g.bomb.timer = 20.;
        g.bots[1].health = 100.;
        g.bots[1].pos = g.bomb.pos;
        g.bomb.defuser = Some(1);
        g.bomb.defuse = 3.;
        g.tick_bomb(0.05, false);
        assert_eq!(g.bomb.defuser, Some(1));
        assert!(g.bomb.defuse > 3.);
        g.bots[1].health = 0.;
        g.tick_bomb(0.05, false);
        assert_eq!(g.bomb.defuser, Some(0));
        assert!(g.bomb.defuse < 0.1, "A real handoff must restart defusing");
    }
    #[test]
    fn path_smoothing_never_cuts_a_blocked_corner() {
        let mut g = arena();
        g.map.tiles[21][21] = 1;
        assert!(
            !g.map
                .walkable_segment(Point::new(20.5, 21.5), Point::new(21.5, 20.5))
        );
        assert!(
            g.map
                .walkable_segment(Point::new(18.5, 19.5), Point::new(20.5, 20.5))
        );
    }
}
impl Intent {
    pub fn label(self) -> &'static str {
        match self {
            Self::Advance => "ADVANCING",
            Self::Hold => "HOLDING",
            Self::Engage => "ENGAGING",
            Self::Reposition => "REPOSITIONING",
            Self::Investigate => "CHECKING CONTACT",
            Self::Retrieve => "RECOVERING BOMB",
            Self::Plant => "PLANTING",
            Self::Defuse => "DEFUSING",
            Self::Cover => "COVERING SITE",
        }
    }
}
#[derive(Clone, Copy, Debug)]
pub struct Contact {
    pub pos: Point,
    pub ttl: f32,
}

fn angle_delta(to: f32, from: f32) -> f32 {
    (to - from + PI).rem_euclid(TAU) - PI
}
fn bearing(from: Point, to: Point) -> f32 {
    (from.x - to.x).atan2(from.z - to.z)
}

impl Game {
    fn actor(&self, i: usize) -> (Point, bool) {
        if i == 9 {
            (self.pos, self.health > 0.)
        } else {
            (self.bots[i].pos, self.bots[i].health > 0.)
        }
    }
    fn detects(&self, i: usize, pos: Point) -> bool {
        let b = &self.bots[i];
        let d = b.pos.distance(pos);
        d <= 21.
            && (d < 3.2 || angle_delta(bearing(b.pos, pos), b.yaw).abs() < 1.25)
            && self.map.visible(b.pos, pos)
    }
    pub(super) fn hear_shot(&mut self, source: Team, pos: Point) {
        for b in &mut self.bots {
            if b.team != source && b.health > 0. && b.pos.distance(pos) < 17. && b.target.is_none()
            {
                b.contact = Some(Contact { pos, ttl: 2.8 });
                b.think = b.think.min(0.15);
            }
        }
    }
    fn share_contact(&mut self, i: usize, pos: Point) {
        let (team, from) = (self.bots[i].team, self.bots[i].pos);
        self.bots[i].contact = Some(Contact { pos, ttl: 4.5 });
        for (j, b) in self.bots.iter_mut().enumerate() {
            if j != i
                && b.team == team
                && b.health > 0.
                && b.pos.distance(from) < 18.
                && b.target.is_none()
                && b.contact.is_none_or(|c| c.ttl < 1.)
            {
                // A teammate shares a location, never permission to shoot through a wall.
                b.contact = Some(Contact { pos, ttl: 3. });
            }
        }
    }
    pub(super) fn objective_runner(&self, team: Team) -> Option<usize> {
        if team == Team::Ct && self.bomb.defuser == Some(9) {
            return None;
        }
        if let Some(i) = self.bomb.defuser.filter(|i| *i < 9) {
            if team == Team::Ct && self.bots[i].health > 0. {
                return Some(i);
            }
        }
        self.bots
            .iter()
            .enumerate()
            .filter(|(_, b)| b.team == team && b.health > 0.)
            .min_by(|(_, a), (_, b)| {
                a.pos
                    .distance(self.bomb.pos)
                    .total_cmp(&b.pos.distance(self.bomb.pos))
            })
            .map(|(i, _)| i)
    }
    fn guard_position(&self, i: usize) -> Point {
        let center = self.bomb.pos;
        // Different operators hold different approaches instead of standing on the bomb.
        for offset in 0..12 {
            let angle = (i * 5 + offset) as f32 * TAU / 12.;
            let radius = if offset < 6 { 3.6 } else { 5.2 };
            let p = Point::new(
                center.x + angle.cos() * radius,
                center.z + angle.sin() * radius,
            );
            if self.map.can_stand(p) && self.map.visible(p, center) {
                return p;
            }
        }
        center
    }
    fn objective(&self, i: usize) -> (Point, Intent) {
        let b = &self.bots[i];
        if self.bomb.state == BombState::Planted {
            if b.team == Team::Ct && self.objective_runner(Team::Ct) == Some(i) {
                return (self.bomb.pos, Intent::Defuse);
            }
            return (self.guard_position(i), Intent::Cover);
        }
        if self.bomb.state == BombState::Dropped && b.team == Team::T {
            if self.objective_runner(Team::T) == Some(i) {
                return (self.bomb.pos, Intent::Retrieve);
            }
            return (self.guard_position(i), Intent::Cover);
        }
        if self.bomb.carrier == Some(i) && b.pos.distance(SITES[self.bomb.site]) < 1.65 {
            return (b.pos, Intent::Plant);
        }
        (self.route_goal(i), Intent::Advance)
    }
    fn combat_position(&self, i: usize, enemy: Point) -> Option<Point> {
        let b = &self.bots[i];
        let hiding = b.health < 42.;
        let mut best = None;
        let mut score = f32::NEG_INFINITY;
        for dz in -4..=4 {
            for dx in -4..=4 {
                let p = Point::new(
                    b.pos.x.floor() + dx as f32 + 0.5,
                    b.pos.z.floor() + dz as f32 + 0.5,
                );
                let travel = b.pos.distance(p);
                if !(1.1..=4.3).contains(&travel)
                    || !self.map.can_stand(p)
                    || !self.map.walkable_segment(b.pos, p)
                    || p.distance(enemy) < 2.5
                {
                    continue;
                }
                let visible = self.map.visible(p, enemy);
                let cover = [(-1., 0.), (1., 0.), (0., -1.), (0., 1.)]
                    .iter()
                    .any(|(x, z)| self.map.solid(p.x + x, p.z + z));
                let crowd: f32 = self
                    .bots
                    .iter()
                    .enumerate()
                    .filter(|(j, other)| *j != i && other.health > 0.)
                    .map(|(_, other)| (1.8 - other.pos.distance(p)).max(0.) * 3.)
                    .sum();
                let side = ((enemy.x - b.pos.x) * (p.z - b.pos.z)
                    - (enemy.z - b.pos.z) * (p.x - b.pos.x))
                    .signum();
                let value = if hiding {
                    if visible { -4. } else { 6. }
                } else if visible {
                    2.
                } else {
                    -2.
                } + if cover { 2.5 } else { 0. }
                    - travel * 0.3
                    - (p.distance(enemy) - 8.).abs() * 0.12
                    - crowd
                    + side * if i % 2 == 0 { 0.45 } else { -0.45 };
                if value > score {
                    score = value;
                    best = Some(p);
                }
            }
        }
        best
    }
    fn plan_bot(&mut self, i: usize) {
        let p = self.bots[i].pos;
        let team = self.bots[i].team;
        let mut best = None;
        let mut distance = 21.;
        for j in 0..=9 {
            if j == i || (j == 9 && team == Team::Ct) || (j < 9 && self.bots[j].team == team) {
                continue;
            }
            let (pos, alive) = self.actor(j);
            // Keep a visible acquired target even if turning/repositioning briefly
            // moves it outside peripheral vision; hidden positions are never tracked.
            let seen = if self.bots[i].target == Some(j) {
                self.map.visible(p, pos)
            } else {
                self.detects(i, pos)
            };
            let d = p.distance(pos);
            if alive && d < distance && seen {
                best = Some(j);
                distance = d;
            }
        }
        if best != self.bots[i].target {
            self.bots[i].cooldown = self.bots[i].cooldown.max(0.45 + self.random() * 0.2);
            self.bots[i].burst_left = 3;
            // Losing sight must not cancel a wounded operator's retreat.
            if best.is_some() {
                self.bots[i].tactic_time = 0.;
            }
        }
        self.bots[i].target = best;
        let (mut goal, mut intent) = self.objective(i);
        if let Some(target) = best {
            let enemy = self.actor(target).0;
            self.share_contact(i, enemy);
            let urgent_defuse =
                intent == Intent::Defuse && self.bomb.timer < 9. && p.distance(self.bomb.pos) < 1.4;
            if !urgent_defuse {
                if self.bots[i].tactic_time <= 0. {
                    self.bots[i].tactical_goal = self.combat_position(i, enemy);
                    self.bots[i].tactic_time = 2.2 + self.random() * 1.6;
                }
                goal = self.bots[i].tactical_goal.unwrap_or(p);
                intent = if p.distance(goal) > 0.3 {
                    Intent::Reposition
                } else {
                    Intent::Engage
                };
            }
        } else if let Some(contact) = self.bots[i].contact {
            let objective_busy = intent == Intent::Plant
                || intent == Intent::Retrieve
                || (self.bomb.state == BombState::Planted
                    && (p.distance(self.bomb.pos) < 7.
                        || contact.pos.distance(self.bomb.pos) > 11.));
            let retreat = self.bots[i].tactical_goal.filter(|cover| {
                self.bots[i].health < 42.
                    && self.bots[i].tactic_time > 0.6
                    && !self.map.visible(*cover, contact.pos)
                    && self.map.walkable_segment(p, *cover)
            });
            if let Some(cover) = retreat.filter(|_| !objective_busy) {
                goal = cover;
                intent = if p.distance(cover) > 0.3 {
                    Intent::Reposition
                } else {
                    Intent::Hold
                };
            } else if !objective_busy && p.distance(contact.pos) > 0.9 {
                goal = contact.pos;
                intent = Intent::Investigate;
            } else if p.distance(contact.pos) <= 0.9 {
                self.bots[i].contact = None;
            }
        }
        if intent == Intent::Advance && p.distance(goal) < 0.7 {
            if team == Team::T {
                self.bots[i].route = (self.bots[i].route + 1).min(2);
                goal = self.route_goal(i);
            } else {
                intent = Intent::Hold;
            }
        }
        if matches!(intent, Intent::Engage | Intent::Plant | Intent::Hold) {
            goal = p;
        }
        self.bots[i].intent = intent;
        if self.bots[i]
            .path
            .back()
            .is_none_or(|end| end.distance(goal) > 0.4)
        {
            self.bots[i].path = self.map.path(p, goal);
        }
    }
    fn move_bot(&mut self, i: usize, dt: f32) {
        let p = self.bots[i].pos;
        // Skip intermediate grid centres only when the operator's full radius fits.
        while self.bots[i].path.len() > 1 {
            let next = self.bots[i].path[1];
            if p.distance(next) < 3. && self.map.walkable_segment(p, next) {
                self.bots[i].path.pop_front();
            } else {
                break;
            }
        }
        let stop = self.bots[i].intent == Intent::Plant
            || (self.bots[i].intent == Intent::Defuse && p.distance(self.bomb.pos) < 1.25);
        if !stop {
            if let Some(next) = self.bots[i].path.front().copied() {
                let d = p.distance(next);
                if d < 0.14 {
                    self.bots[i].path.pop_front();
                } else {
                    let speed = if self.bots[i].target.is_some() {
                        1.75
                    } else {
                        2.25
                    };
                    let step = (dt * speed).min(d);
                    let mut dx = (next.x - p.x) / d * step;
                    let mut dz = (next.z - p.z) / d * step;
                    for (j, other) in self.bots.iter().enumerate() {
                        let distance = p.distance(other.pos);
                        if j != i && other.health > 0. && (0.001..0.85).contains(&distance) {
                            dx += (p.x - other.pos.x) / distance * dt * (0.85 - distance) * 1.3;
                            dz += (p.z - other.pos.z) / distance * dt * (0.85 - distance) * 1.3;
                        }
                    }
                    self.map.move_by(&mut self.bots[i].pos, dx, dz);
                    self.bots[i].moving = p.distance(self.bots[i].pos) > 0.002;
                    if !self.bots[i].moving {
                        self.bots[i].stuck += dt;
                    } else {
                        self.bots[i].stuck = 0.;
                    }
                    if self.bots[i].stuck > 0.8 {
                        self.bots[i].path.clear();
                        self.bots[i].tactic_time = 0.;
                        self.bots[i].think = 0.;
                        self.bots[i].stuck = 0.;
                    }
                }
            }
        }
        let watch = if let Some(target) = self.bots[i].target {
            self.actor(target).0
        } else if let Some(contact) = self.bots[i].contact {
            contact.pos
        } else if self.bots[i].moving {
            self.bots[i].pos
        } else if self.bots[i].team == Team::Ct {
            [
                Point::layout(4.5, 13.),
                Point::layout(26.5, 14.),
                Point::layout(16., 14.),
                Point::layout(22., 10.),
            ][i]
        } else {
            PLAYER_SPAWN
        };
        let sweep = if self.bots[i].moving
            || self.bots[i].target.is_some()
            || self.bots[i].contact.is_some()
        {
            0.
        } else {
            (self.clock * 0.65 + i as f32).sin() * 0.55
        };
        let desired = bearing(p, watch) + sweep;
        self.bots[i].yaw += angle_delta(desired, self.bots[i].yaw).clamp(-dt * 5.5, dt * 5.5);
    }
    fn bot_shoot(&mut self, i: usize, target: usize) {
        let (p, dest, team) = (self.bots[i].pos, self.actor(target).0, self.bots[i].team);
        let range = p.distance(dest);
        if angle_delta(bearing(p, dest), self.bots[i].yaw).abs() > 0.18 {
            return;
        }
        let from = [p.x, self.map.elevation(p.x, p.z) + 1.4, p.z];
        let chance = (0.78
            - range * 0.018
            - if self.bots[i].moving { 0.2 } else { 0. }
            - if target == 9 { 0.05 } else { 0. })
        .clamp(0.18, 0.72);
        let miss = if self.random() < chance {
            0.
        } else {
            (0.55 + self.random() * 0.85) * if self.random() < 0.5 { -1. } else { 1. }
        };
        let mut dir = [
            dest.x - p.x + (dest.z - p.z) / range.max(0.01) * miss,
            self.map.elevation(dest.x, dest.z) + 1.25 - from[1],
            dest.z - p.z - (dest.x - p.x) / range.max(0.01) * miss,
        ];
        let length = dir.iter().map(|v| v * v).sum::<f32>().sqrt().max(0.0001);
        for value in &mut dir {
            *value /= length;
        }
        let mut distance = self.map.raycast(from, dir, 40.);
        let mut impact = if distance < 40. {
            Impact::World
        } else {
            Impact::Miss
        };
        let mut victim = None;
        for j in 0..=9 {
            let (pos, alive) = self.actor(j);
            if j == i || !alive {
                continue;
            }
            let y = self.map.elevation(pos.x, pos.z);
            if let Some(hit) = ray_box(
                from,
                dir,
                [pos.x - 0.3, y + 0.15, pos.z - 0.23],
                [pos.x + 0.3, y + 1.9, pos.z + 0.23],
            ) {
                if hit < distance {
                    distance = hit;
                    victim = Some(j);
                    impact = Impact::Actor;
                }
            }
        }
        let friendly = victim.is_some_and(|j| {
            if j == 9 {
                team == Team::Ct
            } else {
                self.bots[j].team == team
            }
        });
        if friendly {
            // Hold fire and look for another angle when a teammate crosses the muzzle.
            self.bots[i].cooldown = 0.2;
            self.bots[i].tactic_time = 0.;
            return;
        }
        self.shots.push(Shot {
            from,
            to: std::array::from_fn(|axis| from[axis] + dir[axis] * distance),
            impact,
        });
        self.bots[i].flash = 0.055;
        self.bots[i].spotted = 2.;
        self.hear_shot(team, p);
        self.bots[i].burst_left -= 1;
        self.bots[i].cooldown = if self.bots[i].burst_left == 0 {
            self.bots[i].burst_left = 3;
            1.15 + self.random() * 0.65
        } else {
            0.17 + self.random() * 0.06
        };
        if let Some(j) = victim {
            if j == 9 {
                let damage = 10. + self.random() * 6.;
                let absorbed = self.armor.min(damage * 0.45);
                self.armor -= absorbed;
                self.health = (self.health - damage + absorbed).max(0.);
                self.damage_flash = 0.65;
                self.hurt_serial += 1;
                if self.health == 0. {
                    self.deaths += 1;
                    self.bots[i].kills += 1;
                    self.record_kill(NAMES[i], "YOU", Team::T, false);
                    self.reload = 0.;
                }
            } else {
                self.bots[j].health -= 18. + self.random() * 8.;
                if self.bots[j].health <= 0. {
                    self.kill_bot(j, Some(i), false);
                }
            }
        }
    }
    pub(super) fn tick_bots(&mut self, dt: f32) {
        for i in 0..self.bots.len() {
            if self.bots[i].health <= 0. {
                continue;
            }
            self.bots[i].moving = false;
            self.bots[i].cooldown -= dt;
            self.bots[i].think -= dt;
            self.bots[i].tactic_time -= dt;
            if let Some(c) = &mut self.bots[i].contact {
                c.ttl -= dt;
            }
            if self.bots[i].contact.is_some_and(|c| c.ttl <= 0.) {
                self.bots[i].contact = None;
            }
            if let Some(target) = self.bots[i].target {
                let (pos, alive) = self.actor(target);
                if !alive || !self.map.visible(self.bots[i].pos, pos) {
                    self.bots[i].target = None;
                    self.bots[i].think = 0.;
                }
            }
            if self.bots[i].think <= 0. {
                self.plan_bot(i);
                self.bots[i].think = 0.22 + self.random() * 0.12;
            }
            self.move_bot(i, dt);
            if let Some(target) = self.bots[i].target {
                let defusing = self.bots[i].intent == Intent::Defuse
                    && self.bots[i].pos.distance(self.bomb.pos) < 1.4;
                if !defusing
                    && self.bots[i].cooldown <= 0.
                    && self.map.visible(self.bots[i].pos, self.actor(target).0)
                {
                    self.bot_shoot(i, target);
                }
            }
        }
    }
}
