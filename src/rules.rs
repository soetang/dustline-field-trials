//! Deterministic gameplay, independent of the renderer. Run with `bash scripts/check.sh`.
use std::collections::VecDeque;
#[path = "ai.rs"]
pub mod ai;
#[path = "scenery.rs"]
pub mod scenery;
#[path = "terrain.rs"]
pub mod terrain;

// Layout coordinates retain the authored three-lane plan; physics stays in metres.
pub const LAYOUT_SCALE: usize = 2;
pub const W: usize = 32 * LAYOUT_SCALE;
pub const H: usize = 24 * LAYOUT_SCALE;
pub const PLAYER_SPAWN: Point = Point::layout(16.2, 3.8);
pub const SITES: [Point; 2] = [Point::layout(5.8, 4.4), Point::layout(26.1, 4.8)];
pub const CT_SPAWNS: [Point; 4] = [
    Point::layout(15.1, 3.5),
    Point::layout(17.2, 3.4),
    Point::layout(15.2, 5.1),
    Point::layout(18.3, 5.2),
];
pub const T_SPAWNS: [Point; 5] = [
    Point::layout(14.1, 20.2),
    Point::layout(15.3, 21.1),
    Point::layout(16.4, 20.1),
    Point::layout(17.6, 21.1),
    Point::layout(17.5, 19.5),
];
pub const NAMES: [&str; 9] = [
    "FALCON", "BISHOP", "NOVA", "LOCKE", "VIPER", "ROOK", "DUNE", "RAZOR", "KANE",
];

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f32,
    pub z: f32,
}
impl Point {
    pub const fn new(x: f32, z: f32) -> Self {
        Self { x, z }
    }
    pub const fn layout(x: f32, z: f32) -> Self {
        Self::new(x * LAYOUT_SCALE as f32, z * LAYOUT_SCALE as f32)
    }
    pub fn distance(self, other: Self) -> f32 {
        (self.x - other.x).hypot(self.z - other.z)
    }
    fn cell(self) -> (usize, usize) {
        (
            self.x.floor().clamp(0., (W - 1) as f32) as usize,
            self.z.floor().clamp(0., (H - 1) as f32) as usize,
        )
    }
}

#[derive(Clone)]
pub struct Map {
    pub tiles: [[u8; W]; H],
    pub heights: [[f32; W + 1]; H + 1],
}
impl Default for Map {
    fn default() -> Self {
        let mut tiles = [[1; W]; H];
        for (x1, z1, x2, z2) in [
            (2, 2, 10, 7),
            (22, 2, 29, 8),
            (14, 2, 20, 6),
            (13, 19, 18, 22),
            (13, 5, 18, 20),
            (2, 6, 5, 20),
            (2, 17, 14, 21),
            (5, 4, 14, 7),
            (8, 9, 14, 12),
            (7, 6, 10, 10),
            (23, 7, 28, 20),
            (18, 18, 28, 21),
            (19, 5, 24, 8),
            (18, 4, 23, 6),
            (18, 13, 25, 16),
            (16, 12, 20, 15),
        ] {
            for row in tiles
                .iter_mut()
                .take((z2 + 1) * LAYOUT_SCALE)
                .skip(z1 * LAYOUT_SCALE)
            {
                for tile in row
                    .iter_mut()
                    .take((x2 + 1) * LAYOUT_SCALE)
                    .skip(x1 * LAYOUT_SCALE)
                {
                    *tile = 0;
                }
            }
        }
        for (x, z, t) in [
            (7, 3, 3),
            (9, 6, 3),
            (4, 10, 3),
            (4, 18, 3),
            (9, 19, 3),
            (11, 6, 2),
            (15, 9, 2),
            (17, 14, 3),
            (19, 5, 3),
            (23, 5, 3),
            (25, 3, 3),
            (28, 7, 3),
            (25, 11, 3),
            (23, 15, 3),
            (26, 19, 3),
        ] {
            for row in tiles.iter_mut().skip(z * LAYOUT_SCALE).take(LAYOUT_SCALE) {
                for tile in row.iter_mut().skip(x * LAYOUT_SCALE).take(LAYOUT_SCALE) {
                    *tile = t;
                }
            }
        }
        // Opposite-side openings force a dogleg through mid. These are full-height
        // collision/visibility walls, not decorative props hiding a live sightline.
        for (x1, z1, x2, z2) in [(26, 17, 33, 18), (31, 24, 37, 25)] {
            for row in tiles.iter_mut().take(z2 + 1).skip(z1) {
                for tile in row.iter_mut().take(x2 + 1).skip(x1) {
                    *tile = 1;
                }
            }
        }
        Self {
            tiles,
            heights: std::array::from_fn(|z| {
                std::array::from_fn(|x| terrain::elevation(x as f32, z as f32))
            }),
        }
    }
}
impl Map {
    pub fn elevation(&self, x: f32, z: f32) -> f32 {
        let ix = x.floor().clamp(0., (W - 1) as f32) as usize;
        let iz = z.floor().clamp(0., (H - 1) as f32) as usize;
        let (u, v) = ((x - ix as f32).clamp(0., 1.), (z - iz as f32).clamp(0., 1.));
        let (a, b, c, d) = (
            self.heights[iz][ix],
            self.heights[iz][ix + 1],
            self.heights[iz + 1][ix],
            self.heights[iz + 1][ix + 1],
        );
        if u + v <= 1. {
            a + (b - a) * u + (c - a) * v
        } else {
            d + (c - d) * (1. - u) + (b - d) * (1. - v)
        }
    }
    pub fn ground_triangles(&self, x: usize, z: usize) -> [[[f32; 3]; 3]; 2] {
        let a = [x as f32, self.heights[z][x], z as f32];
        let b = [x as f32 + 1., self.heights[z][x + 1], z as f32];
        let c = [x as f32, self.heights[z + 1][x], z as f32 + 1.];
        let d = [x as f32 + 1., self.heights[z + 1][x + 1], z as f32 + 1.];
        [[a, c, b], [b, c, d]]
    }
    pub fn tile_bounds(&self, x: usize, z: usize) -> Option<([f32; 3], [f32; 3])> {
        let (height, inset) = match self.tiles[z][x] {
            1 => (2.8, 0.),
            2 => (1.65, 0.03),
            3 => (1.18, 0.07),
            _ => return None,
        };
        let corners = [
            self.heights[z][x],
            self.heights[z][x + 1],
            self.heights[z + 1][x],
            self.heights[z + 1][x + 1],
        ];
        let base = corners.into_iter().fold(f32::INFINITY, f32::min);
        let top = if self.tiles[z][x] == 1 {
            corners.into_iter().fold(0., f32::max)
        } else {
            base
        };
        Some((
            [x as f32 + inset, base, z as f32 + inset],
            [x as f32 + 1. - inset, top + height, z as f32 + 1. - inset],
        ))
    }
    pub fn solid(&self, x: f32, z: f32) -> bool {
        !x.is_finite()
            || !z.is_finite()
            || x < 0.
            || z < 0.
            || x >= W as f32
            || z >= H as f32
            || self.tiles[z.floor() as usize][x.floor() as usize] != 0
    }
    pub fn can_stand(&self, p: Point) -> bool {
        [-0.24, 0.24].into_iter().all(|dx| {
            [-0.24, 0.24]
                .into_iter()
                .all(|dz| !self.solid(p.x + dx, p.z + dz))
        })
    }
    pub fn move_by(&self, p: &mut Point, dx: f32, dz: f32) {
        // Substeps prevent tunnelling on a slow frame or a large displacement.
        let steps = (dx.abs().max(dz.abs()) / 0.12).ceil().max(1.) as u32;
        for _ in 0..steps {
            if self.can_stand(Point::new(p.x + dx / steps as f32, p.z)) {
                p.x += dx / steps as f32;
            }
            if self.can_stand(Point::new(p.x, p.z + dz / steps as f32)) {
                p.z += dz / steps as f32;
            }
        }
    }
    pub fn path(&self, from: Point, to: Point) -> VecDeque<Point> {
        let start = from.cell();
        let goal = to.cell();
        let mut previous = [[None; W]; H];
        let mut queue = VecDeque::from([start]);
        previous[start.1][start.0] = Some(start);
        while let Some((x, z)) = queue.pop_front() {
            if (x, z) == goal {
                break;
            }
            for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x as i32 + dx;
                let nz = z as i32 + dz;
                if nx < 0 || nz < 0 || nx >= W as i32 || nz >= H as i32 {
                    continue;
                }
                let (nx, nz) = (nx as usize, nz as usize);
                if self.tiles[nz][nx] == 0 && previous[nz][nx].is_none() {
                    previous[nz][nx] = Some((x, z));
                    queue.push_back((nx, nz));
                }
            }
        }
        let mut result = VecDeque::new();
        let mut cell = goal;
        if previous[goal.1][goal.0].is_none() {
            return result;
        }
        while cell != start {
            result.push_front(Point::new(cell.0 as f32 + 0.5, cell.1 as f32 + 0.5));
            cell = previous[cell.1][cell.0].unwrap();
        }
        result.push_back(to);
        result
    }
    pub fn walkable_segment(&self, from: Point, to: Point) -> bool {
        let steps = (from.distance(to) * 6.).ceil().max(1.) as usize;
        (0..=steps).all(|step| {
            let t = step as f32 / steps as f32;
            self.can_stand(Point::new(
                from.x + (to.x - from.x) * t,
                from.z + (to.z - from.z) * t,
            ))
        })
    }
    pub fn raycast(&self, origin: [f32; 3], dir: [f32; 3], max: f32) -> f32 {
        let mut nearest = max;
        if dir[1] < -0.0001 {
            nearest = nearest.min(-origin[1] / dir[1]);
        }
        // Traverse only crossed cells (DDA), retaining exact 3D cover hitboxes.
        // A larger arena must not make every bot sight check scan the entire map.
        let Some(entry) = ray_box(
            origin,
            dir,
            [0., f32::NEG_INFINITY, 0.],
            [W as f32, f32::INFINITY, H as f32],
        ) else {
            return nearest;
        };
        if entry > nearest {
            return nearest;
        }
        let mut x = (origin[0] + dir[0] * (entry + 0.00001))
            .floor()
            .clamp(0., (W - 1) as f32) as i32;
        let mut z = (origin[2] + dir[2] * (entry + 0.00001))
            .floor()
            .clamp(0., (H - 1) as f32) as i32;
        let step_x = if dir[0] > 0. { 1 } else { -1 };
        let step_z = if dir[2] > 0. { 1 } else { -1 };
        let boundary = |cell: i32, step: i32, o: f32, d: f32| {
            if d.abs() < 0.00001 {
                f32::INFINITY
            } else {
                ((cell + i32::from(step > 0)) as f32 - o) / d
            }
        };
        let mut next_x = boundary(x, step_x, origin[0], dir[0]);
        let mut next_z = boundary(z, step_z, origin[2], dir[2]);
        let delta_x = if dir[0].abs() < 0.00001 {
            f32::INFINITY
        } else {
            dir[0].recip().abs()
        };
        let delta_z = if dir[2].abs() < 0.00001 {
            f32::INFINITY
        } else {
            dir[2].recip().abs()
        };
        let mut travelled = entry;
        // Hitboxes have closed edges: include both cells when a ray grazes a grid
        // line, including vertical rays and exact diagonal corner crossings.
        let touching = |coordinate: f32, cell: i32| {
            let edge = coordinate.round();
            if (coordinate - edge).abs() < 0.0001 {
                (edge as i32 - 1, edge as i32)
            } else {
                (cell, cell)
            }
        };
        while x >= 0 && z >= 0 && x < W as i32 && z < H as i32 {
            let (x0, x1) = touching(origin[0] + dir[0] * travelled, x);
            let (z0, z1) = touching(origin[2] + dir[2] * travelled, z);
            for tz in z0.max(0)..=z1.min(H as i32 - 1) {
                for tx in x0.max(0)..=x1.min(W as i32 - 1) {
                    let (tx, tz) = (tx as usize, tz as usize);
                    if let Some((min, max)) = self.tile_bounds(tx, tz) {
                        if let Some(t) = ray_box(origin, dir, min, max) {
                            nearest = nearest.min(t);
                        }
                    }
                    // Flat cells are already covered by the base plane above.
                    if self.heights[tz][tx]
                        + self.heights[tz][tx + 1]
                        + self.heights[tz + 1][tx]
                        + self.heights[tz + 1][tx + 1]
                        > 0.
                    {
                        for triangle in self.ground_triangles(tx, tz) {
                            if let Some(t) = terrain::ray_triangle(origin, dir, triangle) {
                                nearest = nearest.min(t);
                            }
                        }
                    }
                }
            }
            if next_x.min(next_z) > nearest {
                break;
            }
            if next_x < next_z {
                travelled = next_x;
                x += step_x;
                next_x += delta_x;
            } else {
                travelled = next_z;
                z += step_z;
                next_z += delta_z;
            }
        }
        nearest
    }
    pub fn visible(&self, a: Point, b: Point) -> bool {
        let ay = self.elevation(a.x, a.z) + 1.5;
        let by = self.elevation(b.x, b.z) + 1.5;
        let d = a.distance(b).hypot(by - ay);
        d < 0.01
            || self.raycast(
                [a.x, ay, a.z],
                [(b.x - a.x) / d, (by - ay) / d, (b.z - a.z) / d],
                d,
            ) >= d - 0.05
    }
}

pub fn ray_box(o: [f32; 3], d: [f32; 3], min: [f32; 3], max: [f32; 3]) -> Option<f32> {
    let mut near: f32 = 0.;
    let mut far: f32 = f32::INFINITY;
    for axis in 0..3 {
        if d[axis].abs() < 0.00001 {
            if o[axis] < min[axis] || o[axis] > max[axis] {
                return None;
            }
        } else {
            let a = (min[axis] - o[axis]) / d[axis];
            let b = (max[axis] - o[axis]) / d[axis];
            near = near.max(a.min(b));
            far = far.min(a.max(b));
        }
    }
    if near <= far && far >= 0. {
        Some(near)
    } else {
        None
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Team {
    Ct,
    T,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Weapon {
    M4,
    Ak,
    Awp,
    Deagle,
}
#[derive(Clone, Copy)]
pub struct WeaponSpec {
    pub name: &'static str,
    pub price: u32,
    pub mag: u16,
    pub reserve: u16,
    pub damage: f32,
    pub interval: f32,
    pub reload: f32,
    pub auto: bool,
}
#[derive(Clone, Copy)]
pub struct AccuracySpec {
    pub hip: f32,
    pub aimed: f32,
    pub moving: f32,
    pub per_shot: f32,
    pub maximum: f32,
    pub recovery: f32,
    pub settle: f32,
}
impl Weapon {
    pub fn accuracy(self) -> AccuracySpec {
        let (hip, aimed, moving, per_shot, maximum, recovery, settle) = match self {
            Self::M4 => (0.0045, 0.0015, 0.022, 0.003, 0.027, 0.045, 0.12),
            Self::Ak => (0.006, 0.0022, 0.031, 0.0045, 0.045, 0.045, 0.17),
            Self::Awp => (0.04, 0.0004, 0.095, 0.028, 0.03, 0.075, 0.2),
            Self::Deagle => (0.009, 0.0035, 0.038, 0.014, 0.035, 0.04, 0.22),
        };
        AccuracySpec {
            hip,
            aimed,
            moving,
            per_shot,
            maximum,
            recovery,
            settle,
        }
    }
    pub fn spec(self) -> WeaponSpec {
        match self {
            Self::M4 => WeaponSpec {
                name: "M4A4",
                price: 3100,
                mag: 30,
                reserve: 90,
                damage: 31.,
                interval: 0.092,
                reload: 2.25,
                auto: true,
            },
            Self::Ak => WeaponSpec {
                name: "AK-47",
                price: 2700,
                mag: 30,
                reserve: 90,
                damage: 36.,
                interval: 0.1,
                reload: 2.4,
                auto: true,
            },
            Self::Awp => WeaponSpec {
                name: "AWP",
                price: 4750,
                mag: 10,
                reserve: 30,
                damage: 112.,
                interval: 1.08,
                reload: 3.15,
                auto: false,
            },
            Self::Deagle => WeaponSpec {
                name: "DESERT EAGLE",
                price: 700,
                mag: 7,
                reserve: 35,
                damage: 54.,
                interval: 0.29,
                reload: 2.05,
                auto: false,
            },
        }
    }
    pub fn slot(self) -> usize {
        match self {
            Self::M4 => 0,
            Self::Ak => 1,
            Self::Awp => 2,
            Self::Deagle => 3,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Bot {
    pub team: Team,
    pub pos: Point,
    pub health: f32,
    pub yaw: f32,
    pub flash: f32,
    pub kills: u32,
    pub deaths: u32,
    pub spotted: f32,
    pub moving: bool,
    pub intent: ai::Intent,
    contact: Option<ai::Contact>,
    tactical_goal: Option<Point>,
    tactic_time: f32,
    burst_left: u8,
    stuck: f32,
    path: VecDeque<Point>,
    think: f32,
    cooldown: f32,
    route: usize,
    target: Option<usize>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Buy,
    Live,
    End,
    Finished,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BombState {
    Carried,
    Dropped,
    Planted,
    Defused,
    Exploded,
}
pub struct Bomb {
    pub state: BombState,
    pub pos: Point,
    pub carrier: Option<usize>,
    pub site: usize,
    pub timer: f32,
    pub plant: f32,
    pub defuse: f32,
    pub defuser: Option<usize>,
}
pub struct Feed {
    pub killer: &'static str,
    pub victim: &'static str,
    pub team: Team,
    pub headshot: bool,
    pub ttl: f32,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Impact {
    Miss,
    World,
    Actor,
}
#[derive(Clone, Copy)]
pub struct Shot {
    pub from: [f32; 3],
    pub to: [f32; 3],
    pub impact: Impact,
}
pub struct Game {
    pub map: Map,
    pub pos: Point,
    pub health: f32,
    pub armor: f32,
    pub weapon: Weapon,
    pub ammo: u16,
    pub reserve: u16,
    pub reload: f32,
    pub cooldown: f32,
    pub bloom: f32,
    bloom_delay: f32,
    pub money: u32,
    pub kills: u32,
    pub deaths: u32,
    pub bots: Vec<Bot>,
    pub phase: Phase,
    pub phase_time: f32,
    pub round: u32,
    pub clock: f32,
    pub buy_time: f32,
    pub scores: [u32; 2],
    pub bomb: Bomb,
    pub winner: Team,
    pub reason: &'static str,
    pub notice: &'static str,
    pub notice_time: f32,
    pub hitmarker: f32,
    pub headshot: bool,
    pub damage_flash: f32,
    pub shots: Vec<Shot>,
    pub feed: VecDeque<Feed>,
    pub shot_serial: u32,
    pub hurt_serial: u32,
    pub kill_serial: u32,
    pub seed: u32,
    rng: u32,
}
impl Default for Game {
    fn default() -> Self {
        let mut game = Self {
            map: Map::default(),
            pos: PLAYER_SPAWN,
            health: 100.,
            armor: 100.,
            weapon: Weapon::M4,
            ammo: 30,
            reserve: 90,
            reload: 0.,
            cooldown: 0.,
            bloom: 0.,
            bloom_delay: 0.,
            money: 8000,
            kills: 0,
            deaths: 0,
            bots: vec![],
            phase: Phase::Buy,
            phase_time: 7.,
            round: 1,
            clock: 90.,
            buy_time: 20.,
            scores: [0, 0],
            bomb: Bomb {
                state: BombState::Carried,
                pos: T_SPAWNS[0],
                carrier: Some(4),
                site: 0,
                timer: 35.,
                plant: 0.,
                defuse: 0.,
                defuser: None,
            },
            winner: Team::Ct,
            reason: "",
            notice: "",
            notice_time: 0.,
            hitmarker: 0.,
            headshot: false,
            damage_flash: 0.,
            shots: vec![],
            feed: VecDeque::new(),
            shot_serial: 0,
            hurt_serial: 0,
            kill_serial: 0,
            seed: 0x1234abcd,
            rng: 0x1234abcd,
        };
        game.reset_bots();
        game
    }
}
impl Game {
    pub fn seeded(seed: u32) -> Self {
        let mut game = Self::default();
        game.seed = seed.max(1);
        game.rng = game.seed;
        game
    }
    fn random(&mut self) -> f32 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        self.rng as f32 / u32::MAX as f32
    }
    fn reset_bots(&mut self) {
        let stats: Vec<_> = self.bots.iter().map(|b| (b.kills, b.deaths)).collect();
        self.bots = CT_SPAWNS
            .iter()
            .chain(T_SPAWNS.iter())
            .enumerate()
            .map(|(i, p)| Bot {
                team: if i < 4 { Team::Ct } else { Team::T },
                pos: *p,
                health: 100.,
                yaw: if i < 4 { std::f32::consts::PI } else { 0. },
                flash: 0.,
                kills: stats.get(i).map_or(0, |s| s.0),
                deaths: stats.get(i).map_or(0, |s| s.1),
                spotted: 0.,
                moving: false,
                intent: ai::Intent::Advance,
                contact: None,
                tactical_goal: None,
                tactic_time: 0.,
                burst_left: 3,
                stuck: 0.,
                path: VecDeque::new(),
                think: 0.,
                cooldown: 0.6 + i as f32 * 0.09,
                route: 0,
                target: None,
            })
            .collect();
    }
    pub fn alive(&self, team: Team) -> usize {
        self.bots
            .iter()
            .filter(|b| b.team == team && b.health > 0.)
            .count()
            + usize::from(team == Team::Ct && self.health > 0.)
    }
    pub fn notify(&mut self, text: &'static str) {
        self.notice = text;
        self.notice_time = 2.5;
    }
    pub fn buy(&mut self, weapon: Weapon) -> bool {
        if self.health <= 0.
            || !matches!(self.phase, Phase::Buy | Phase::Live)
            || self.buy_time <= 0.
        {
            self.notify("Buy period has ended");
            return false;
        }
        if self.pos.distance(PLAYER_SPAWN) > 4.5 {
            self.notify("Return to CT spawn to buy");
            return false;
        }
        let spec = weapon.spec();
        if self.money < spec.price {
            self.notify("Not enough credits");
            return false;
        }
        self.money -= spec.price;
        self.weapon = weapon;
        self.ammo = spec.mag;
        self.reserve = spec.reserve;
        self.reload = 0.;
        self.cooldown = 0.25;
        self.bloom = 0.;
        self.bloom_delay = 0.;
        self.notify("Loadout equipped");
        true
    }
    pub fn start_reload(&mut self) -> bool {
        if self.health <= 0.
            || self.reload > 0.
            || self.reserve == 0
            || self.ammo == self.weapon.spec().mag
            || !matches!(self.phase, Phase::Buy | Phase::Live)
        {
            return false;
        }
        self.reload = self.weapon.spec().reload;
        true
    }
    pub fn fire(
        &mut self,
        origin: [f32; 3],
        mut direction: [f32; 3],
        moving: bool,
        aiming: bool,
    ) -> bool {
        if self.phase != Phase::Live
            || self.health <= 0.
            || self.cooldown > 0.
            || self.reload > 0.
            || self.bomb.defuser == Some(9)
        {
            return false;
        }
        if self.ammo == 0 {
            self.start_reload();
            return false;
        }
        let length = direction.iter().map(|n| n * n).sum::<f32>().sqrt();
        if !origin.iter().chain(direction.iter()).all(|n| n.is_finite()) || length < 0.00001 {
            return false;
        }
        for n in &mut direction {
            *n /= length;
        }
        let spec = self.weapon.spec();
        self.ammo -= 1;
        self.cooldown = spec.interval;
        self.shot_serial += 1;
        self.hear_shot(Team::Ct, Point::new(origin[0], origin[2]));
        let spread = self.spread(moving, aiming);
        // Uniform disc in aim space: dispersion must not depend on compass direction.
        let radius = self.random().sqrt() * spread;
        let angle = self.random() * std::f32::consts::TAU;
        let horizontal = direction[0].hypot(direction[2]);
        let right = if horizontal > 0.00001 {
            [direction[2] / horizontal, 0., -direction[0] / horizontal]
        } else {
            [1., 0., 0.]
        };
        let up = [
            direction[1] * right[2],
            direction[2] * right[0] - direction[0] * right[2],
            -direction[1] * right[0],
        ];
        let dx = angle.cos() * radius;
        let dy = angle.sin() * radius + self.bloom * 0.25;
        for axis in 0..3 {
            direction[axis] += right[axis] * dx + up[axis] * dy;
        }
        let length = direction.iter().map(|n| n * n).sum::<f32>().sqrt();
        for n in &mut direction {
            *n /= length;
        }
        let accuracy = self.weapon.accuracy();
        self.bloom = (self.bloom + accuracy.per_shot).min(accuracy.maximum);
        self.bloom_delay = accuracy.settle;
        let mut distance = self.map.raycast(origin, direction, 42.);
        let world_hit = distance < 42.;
        let mut best = None;
        for (i, bot) in self.bots.iter().enumerate().filter(|(_, b)| b.health > 0.) {
            let ground = self.map.elevation(bot.pos.x, bot.pos.z);
            if let Some(d) = ray_box(
                origin,
                direction,
                [bot.pos.x - 0.3, ground + 0.15, bot.pos.z - 0.23],
                [bot.pos.x + 0.3, ground + 1.9, bot.pos.z + 0.23],
            ) {
                if d < distance {
                    distance = d;
                    best = Some(i);
                }
            }
        }
        let to = [
            origin[0] + direction[0] * distance,
            origin[1] + direction[1] * distance,
            origin[2] + direction[2] * distance,
        ];
        let friendly = best.is_some_and(|i| self.bots[i].team == Team::Ct);
        self.shots.push(Shot {
            from: origin,
            to,
            impact: if best.is_some() {
                Impact::Actor
            } else if world_hit {
                Impact::World
            } else {
                Impact::Miss
            },
        });
        if let Some(i) = best {
            if friendly {
                self.notify("Friendly — hold your fire");
            } else {
                self.headshot =
                    to[1] - self.map.elevation(self.bots[i].pos.x, self.bots[i].pos.z) > 1.48;
                self.hitmarker = 0.18;
                self.bots[i].health -= spec.damage * if self.headshot { 3.5 } else { 1. };
                self.bots[i].spotted = 3.;
                if self.bots[i].health <= 0. {
                    self.kill_bot(i, None, self.headshot);
                }
            }
        }
        true
    }
    pub fn spread(&self, moving: bool, aiming: bool) -> f32 {
        let profile = self.weapon.accuracy();
        (if moving {
            profile.moving
        } else if aiming {
            profile.aimed
        } else {
            profile.hip
        }) + self.bloom * if aiming && !moving { 0.8 } else { 1. }
    }
    fn recover_accuracy(&mut self, dt: f32) {
        let recovering = (dt - self.bloom_delay).max(0.);
        self.bloom_delay = (self.bloom_delay - dt).max(0.);
        self.bloom = (self.bloom - recovering * self.weapon.accuracy().recovery).max(0.);
    }
    fn record_kill(
        &mut self,
        killer: &'static str,
        victim: &'static str,
        team: Team,
        headshot: bool,
    ) {
        self.feed.push_front(Feed {
            killer,
            victim,
            team,
            headshot,
            ttl: 6.,
        });
        self.feed.truncate(5);
    }
    fn kill_bot(&mut self, victim: usize, killer: Option<usize>, headshot: bool) {
        self.bots[victim].health = 0.;
        self.bots[victim].deaths += 1;
        let (name, team) = if let Some(i) = killer {
            self.bots[i].kills += 1;
            (NAMES[i], self.bots[i].team)
        } else {
            self.kills += 1;
            self.kill_serial += 1;
            self.money = (self.money + 300).min(16000);
            ("YOU", Team::Ct)
        };
        self.record_kill(name, NAMES[victim], team, headshot);
        if self.bomb.carrier == Some(victim) && self.bomb.state == BombState::Carried {
            self.bomb.state = BombState::Dropped;
            self.bomb.pos = self.bots[victim].pos;
            self.bomb.carrier = None;
            self.bomb.plant = 0.;
            self.notify("Bomb dropped");
        }
    }
    pub fn finish(&mut self, team: Team, reason: &'static str) {
        if !matches!(self.phase, Phase::Live | Phase::Buy) {
            return;
        }
        self.winner = team;
        self.reason = reason;
        self.scores[usize::from(team == Team::T)] += 1;
        self.phase = if self.scores.iter().any(|s| *s >= 5) {
            Phase::Finished
        } else {
            Phase::End
        };
        self.phase_time = 5.;
        self.money = (self.money + if team == Team::Ct { 3250 } else { 2000 }).min(16000);
        self.reload = 0.;
        self.bomb.defuser = None;
    }
    pub fn next_round(&mut self) {
        self.round += 1;
        if self.health <= 0. {
            self.weapon = Weapon::M4;
        }
        self.health = 100.;
        self.armor = 100.;
        self.pos = PLAYER_SPAWN;
        self.ammo = self.weapon.spec().mag;
        self.reserve = self.weapon.spec().reserve;
        self.reload = 0.;
        self.cooldown = 0.;
        self.bloom = 0.;
        self.bloom_delay = 0.;
        self.phase = Phase::Buy;
        self.phase_time = 7.;
        self.buy_time = 20.;
        self.clock = 90.;
        self.damage_flash = 0.;
        self.hitmarker = 0.;
        self.feed.clear();
        self.shots.clear();
        self.bomb = Bomb {
            state: BombState::Carried,
            pos: T_SPAWNS[0],
            carrier: Some(4),
            site: (self.round as usize - 1) % 2,
            timer: 35.,
            plant: 0.,
            defuse: 0.,
            defuser: None,
        };
        self.reset_bots();
    }
    pub fn tick(&mut self, dt: f32, defusing: bool) {
        let dt = dt.clamp(0., 0.05);
        self.shots.clear();
        self.cooldown = (self.cooldown - dt).max(0.);
        self.recover_accuracy(dt);
        self.hitmarker = (self.hitmarker - dt).max(0.);
        self.damage_flash = (self.damage_flash - dt * 1.8).max(0.);
        self.notice_time = (self.notice_time - dt).max(0.);
        for f in &mut self.feed {
            f.ttl -= dt;
        }
        self.feed.retain(|f| f.ttl > 0.);
        for bot in &mut self.bots {
            bot.flash = (bot.flash - dt).max(0.);
            bot.spotted = (bot.spotted - dt).max(0.);
        }
        if self.phase == Phase::Finished {
            return;
        }
        if self.phase == Phase::End {
            self.phase_time -= dt;
            if self.phase_time <= 0. {
                self.next_round();
            }
            return;
        }
        self.buy_time = (self.buy_time - dt).max(0.);
        if self.reload > 0. {
            self.reload = (self.reload - dt).max(0.);
            // Quantised simulation steps can leave a microsecond of f32 residue.
            // Complete at the intended boundary instead of waiting an extra frame.
            if self.reload < 0.00001 {
                self.reload = 0.;
            }
            if self.reload == 0. {
                let n = (self.weapon.spec().mag - self.ammo).min(self.reserve);
                self.ammo += n;
                self.reserve -= n;
            }
        }
        if self.phase == Phase::Buy {
            self.phase_time -= dt;
            if self.phase_time <= 0. {
                self.phase = Phase::Live;
                self.notify("Weapons free — defend the sites");
            }
            return;
        }
        self.clock = (self.clock - dt).max(0.);
        self.tick_bots(dt);
        self.tick_bomb(dt, defusing);
        if self.phase != Phase::Live {
            return;
        }
        if self.alive(Team::Ct) == 0 {
            self.finish(Team::T, "Counter-terrorists eliminated");
        } else if self.bomb.state != BombState::Planted && self.alive(Team::T) == 0 {
            self.finish(Team::Ct, "Threat neutralized");
        } else if self.bomb.state != BombState::Planted && self.clock <= 0. {
            self.finish(Team::Ct, "Sites successfully defended");
        }
    }
    fn route_goal(&self, i: usize) -> Point {
        let b = &self.bots[i];
        let site = self.bomb.site;
        if self.bomb.state == BombState::Planted {
            return self.bomb.pos;
        }
        if b.team == Team::Ct {
            let positions = [
                Point::layout(6.0, 6.4),
                Point::layout(24.5, 7.5),
                Point::layout(14.5, 10.5),
                Point::layout(19.5, 6.5),
            ];
            return positions[i];
        }
        if self.bomb.state == BombState::Dropped {
            return self.bomb.pos;
        }
        let routes = if site == 0 {
            [
                [Point::layout(4.5, 19.5), Point::layout(3.5, 11.5), SITES[0]],
                [Point::layout(14.5, 12.5), Point::layout(8.5, 8.5), SITES[0]],
                [
                    Point::layout(16.5, 10.5),
                    Point::layout(12.5, 5.5),
                    SITES[0],
                ],
            ]
        } else {
            [
                [
                    Point::layout(24.5, 19.5),
                    Point::layout(27.5, 11.5),
                    SITES[1],
                ],
                [
                    Point::layout(19.5, 14.5),
                    Point::layout(24.5, 10.5),
                    SITES[1],
                ],
                [
                    Point::layout(16.5, 10.5),
                    Point::layout(21.5, 6.5),
                    SITES[1],
                ],
            ]
        };
        routes[(i - 4) % 3][b.route.min(2)]
    }
    fn tick_bomb(&mut self, dt: f32, defusing: bool) {
        match self.bomb.state {
            BombState::Dropped => {
                if let Some(i) = self.bots.iter().position(|b| {
                    b.team == Team::T && b.health > 0. && b.pos.distance(self.bomb.pos) < 0.8
                }) {
                    self.bomb.carrier = Some(i);
                    self.bomb.state = BombState::Carried;
                }
            }
            BombState::Carried => {
                if let Some(i) = self.bomb.carrier {
                    self.bomb.pos = self.bots[i].pos;
                    if self.bots[i].health > 0.
                        && self.bots[i].target.is_none()
                        && self.bomb.pos.distance(SITES[self.bomb.site]) < 1.65
                    {
                        self.bomb.plant += dt;
                        if self.bomb.plant >= 3. {
                            self.bomb.state = BombState::Planted;
                            self.bomb.carrier = None;
                            self.bomb.timer = 35.;
                            self.notify("Bomb planted — get to the site");
                        }
                    } else {
                        self.bomb.plant = 0.;
                    }
                }
            }
            BombState::Planted => {
                self.bomb.timer = (self.bomb.timer - dt).max(0.);
                let player_can = defusing
                    && self.health > 0.
                    && self.pos.distance(self.bomb.pos) < 1.7
                    && self.map.visible(self.pos, self.bomb.pos);
                let defuser = if player_can {
                    Some(9)
                } else {
                    self.bots.iter().position(|b| {
                        b.team == Team::Ct
                            && b.health > 0.
                            && (b.target.is_none()
                                || (b.intent == ai::Intent::Defuse && self.bomb.timer < 9.))
                            && b.pos.distance(self.bomb.pos) < 1.4
                            && self.map.visible(b.pos, self.bomb.pos)
                    })
                };
                if defuser != self.bomb.defuser {
                    self.bomb.defuse = 0.;
                }
                self.bomb.defuser = defuser;
                if defuser.is_some() {
                    self.bomb.defuse += dt;
                } else {
                    self.bomb.defuse = 0.;
                }
                // The bomb wins ties: defusing must finish before the fuse expires.
                if self.bomb.timer <= 0. {
                    self.bomb.state = BombState::Exploded;
                    self.finish(Team::T, "Bomb detonated");
                } else if self.bomb.defuse >= if defuser == Some(9) { 5. } else { 7. } {
                    self.bomb.state = BombState::Defused;
                    self.finish(Team::Ct, "Bomb defused");
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn live() -> Game {
        let mut g = Game::default();
        g.phase = Phase::Live;
        g
    }
    #[test]
    fn all_floor_and_spawns_are_reachable() {
        let m = Map::default();
        for (z, row) in m.tiles.iter().enumerate() {
            for (x, t) in row.iter().enumerate() {
                if *t == 0 {
                    assert!(
                        !m.path(PLAYER_SPAWN, Point::new(x as f32 + 0.5, z as f32 + 0.5))
                            .is_empty(),
                        "{x},{z}"
                    );
                }
            }
        }
        for p in CT_SPAWNS
            .into_iter()
            .chain(T_SPAWNS)
            .chain(SITES)
            .chain([PLAYER_SPAWN])
        {
            assert!(m.can_stand(p));
        }
    }
    #[test]
    fn collision_blocks_large_steps_and_slides() {
        let m = Map::default();
        let mut p = Point::new(4.5, 7.5);
        m.move_by(&mut p, -5., 1.);
        assert!(p.x >= 4.24 && p.z > 8.4);
        assert!(m.can_stand(p));
    }
    #[test]
    fn rays_respect_real_cover_height() {
        let m = Map::default();
        assert!(m.raycast([14.5, 1., 5.5], [0., 0., 1.], 10.) < 1.);
        assert!(m.raycast([14.5, 1.6, 5.5], [0., 0., 1.], 10.) > 2.5);
        assert_eq!(
            ray_box([0., 3., 0.], [1., 0., 0.], [1., 0., -1.], [2., 2., 1.]),
            None
        );
    }
    #[test]
    fn purchase_checks_funds_location_and_time() {
        let mut g = live();
        assert!(g.buy(Weapon::Awp));
        assert_eq!((g.money, g.ammo, g.reserve), (3250, 10, 30));
        assert!(!g.buy(Weapon::Awp));
        assert_eq!(g.money, 3250);
        g.pos = SITES[0];
        assert!(!g.buy(Weapon::Deagle));
        g.pos = PLAYER_SPAWN;
        g.buy_time = 0.;
        assert!(!g.buy(Weapon::Deagle));
    }
    #[test]
    fn reload_conserves_ammo_and_cannot_restart() {
        let mut g = Game::default();
        g.ammo = 22;
        g.reserve = 3;
        assert!(g.start_reload());
        assert!(!g.start_reload());
        for _ in 0..50 {
            g.tick(0.05, false);
        }
        assert_eq!((g.ammo, g.reserve), (25, 0));
        assert!(!g.start_reload());
    }
    #[test]
    fn reload_finishes_on_its_exact_step_boundary() {
        let mut g = Game::default();
        g.ammo = 27;
        assert!(g.start_reload());
        let ticks = (g.weapon.spec().reload / 0.05).round() as usize;
        for _ in 0..ticks {
            g.tick(0.05, false);
        }
        assert_eq!(g.reload, 0.);
        assert_eq!(g.ammo, 30);
        assert_eq!(g.reserve, 87);
    }
    #[test]
    fn firing_has_cooldown_and_reload_gates() {
        let mut g = live();
        let o = [16.2, 1.62, 3.8];
        let d = [0., 0., 1.];
        assert!(g.fire(o, d, false, true));
        assert!(!g.fire(o, d, false, true));
        assert_eq!(g.ammo, 29);
        g.cooldown = 0.;
        g.start_reload();
        assert!(!g.fire(o, d, false, true));
    }
    #[test]
    fn headshot_kills_rewards_and_drops_bomb() {
        let mut g = live();
        for b in &mut g.bots {
            b.health = 0.;
        }
        g.bots[4].health = 100.;
        g.bots[4].pos = Point::new(g.pos.x, g.pos.z + 3.);
        assert!(g.fire([g.pos.x, 1.7, g.pos.z], [0., 0., 1.], false, true));
        assert_eq!(g.bots[4].health, 0.);
        assert_eq!(g.kills, 1);
        assert_eq!(g.money, 8300);
        assert_eq!(g.bomb.state, BombState::Dropped);
        assert!(g.headshot);
        assert_eq!(g.shots.last().unwrap().impact, Impact::Actor);
    }
    #[test]
    fn friends_block_shots_without_taking_damage() {
        let mut g = live();
        for b in &mut g.bots {
            b.health = 0.;
        }
        g.bots[0].health = 100.;
        g.bots[0].pos = Point::new(g.pos.x, g.pos.z + 1.5);
        g.bots[4].health = 100.;
        g.bots[4].pos = Point::new(g.pos.x, g.pos.z + 3.);
        g.fire([g.pos.x, 1.7, g.pos.z], [0., 0., 1.], false, true);
        assert_eq!(g.bots[0].health, 100.);
        assert_eq!(g.bots[4].health, 100.);
        assert_eq!(g.kills, 0);
        assert_eq!(g.shots.last().unwrap().impact, Impact::Actor);
    }
    #[test]
    fn impacts_require_a_real_surface_not_a_range_endpoint() {
        let mut g = live();
        for bot in &mut g.bots {
            bot.health = 0.;
        }
        let origin = [g.pos.x, 1.7, g.pos.z];
        assert!(g.fire(origin, [0., 1., 0.], false, true));
        assert_eq!(g.shots.last().unwrap().impact, Impact::Miss);
        g.cooldown = 0.;
        assert!(g.fire(origin, [0., -1., 0.], false, true));
        let ground = g.shots.last().unwrap();
        assert_eq!(ground.impact, Impact::World);
        assert!(ground.to[1].abs() < 0.001);
        g.cooldown = 0.;
        assert!(g.fire(origin, [-1., 0., 0.], false, true));
        assert_eq!(g.shots.last().unwrap().impact, Impact::World);
    }
    #[test]
    fn raised_ground_moves_actor_hitboxes_and_headshot_threshold() {
        for relative_height in [0.9, 1.7] {
            let mut g = live();
            for bot in &mut g.bots {
                bot.health = 0.;
            }
            g.pos = Point::new(8., 24.);
            let target = Point::new(8., 27.);
            assert!(g.map.can_stand(g.pos) && g.map.can_stand(target));
            let ground = g.map.elevation(target.x, target.z);
            assert!(ground > 1.5);
            g.bots[4].pos = target;
            g.bots[4].health = 100.;
            let eye = g.map.elevation(g.pos.x, g.pos.z) + 1.7;
            assert!(g.fire(
                [g.pos.x, eye, g.pos.z],
                [0., ground + relative_height - eye, target.z - g.pos.z],
                false,
                true,
            ));
            assert_eq!(g.shots.last().unwrap().impact, Impact::Actor);
            assert_eq!(g.headshot, relative_height > 1.48);
            assert_eq!(g.bots[4].health <= 0., relative_height > 1.48);
        }
    }
    #[test]
    fn walls_stop_bullets() {
        let mut g = live();
        g.bots[4].pos = Point::layout(10., 3.8);
        assert!(g.map.can_stand(g.bots[4].pos));
        g.fire([g.pos.x, 1.7, g.pos.z], [-1., 0., 0.], false, true);
        assert_eq!(g.bots[4].health, 100.);
    }
    #[test]
    fn round_scores_once_and_resets() {
        let mut g = live();
        g.finish(Team::Ct, "test");
        g.finish(Team::Ct, "test");
        assert_eq!(g.scores, [1, 0]);
        g.health = 0.;
        g.weapon = Weapon::Awp;
        for _ in 0..102 {
            g.tick(0.05, false);
        }
        assert_eq!(g.round, 2);
        assert_eq!(g.health, 100.);
        assert_eq!(g.weapon, Weapon::M4);
        assert_eq!(g.bots.len(), 9);
        assert_eq!(g.phase, Phase::Buy);
    }
    #[test]
    fn planted_bomb_prevents_elimination_win_and_round_timeout() {
        let mut g = live();
        g.bomb.state = BombState::Planted;
        g.bomb.pos = SITES[0];
        g.clock = 0.;
        for b in &mut g.bots {
            if b.team == Team::T {
                b.health = 0.;
            }
        }
        g.tick(0.05, false);
        assert_eq!(g.phase, Phase::Live);
    }
    #[test]
    fn releasing_defuse_clears_progress() {
        let mut g = live();
        g.bomb.state = BombState::Planted;
        g.bomb.pos = g.pos;
        for b in &mut g.bots {
            b.pos = SITES[1];
        }
        for _ in 0..20 {
            g.tick_bomb(0.05, true);
        }
        assert!(g.bomb.defuse > 0.9);
        g.tick_bomb(0.05, false);
        assert_eq!(g.bomb.defuse, 0.);
    }
    #[test]
    fn defuse_wins_but_expired_fuse_wins_ties() {
        let mut g = live();
        g.bomb.state = BombState::Planted;
        g.bomb.pos = g.pos;
        g.bomb.defuser = Some(9);
        g.bomb.defuse = 4.99;
        g.tick_bomb(0.02, true);
        assert_eq!(g.bomb.state, BombState::Defused);
        assert_eq!(g.scores, [1, 0]);
        let mut g = live();
        g.bomb.state = BombState::Planted;
        g.bomb.pos = g.pos;
        g.bomb.timer = 0.01;
        g.bomb.defuser = Some(9);
        g.bomb.defuse = 4.99;
        g.tick_bomb(0.02, true);
        assert_eq!(g.bomb.state, BombState::Exploded);
        assert_eq!(g.scores, [0, 1]);
    }
    #[test]
    fn dropped_bomb_is_recovered_and_planted() {
        let mut g = live();
        g.bomb.state = BombState::Dropped;
        g.bomb.pos = SITES[0];
        g.bomb.carrier = None;
        g.bots[5].pos = SITES[0];
        g.tick_bomb(0.05, false);
        assert_eq!(g.bomb.carrier, Some(5));
        for _ in 0..61 {
            g.tick_bomb(0.05, false);
        }
        assert_eq!(g.bomb.state, BombState::Planted);
    }
    #[test]
    fn match_ends_at_five_rounds() {
        let mut g = live();
        g.scores = [4, 2];
        g.finish(Team::Ct, "test");
        assert_eq!(g.phase, Phase::Finished);
        for _ in 0..200 {
            g.tick(0.05, false);
        }
        assert_eq!(g.scores, [5, 2]);
    }
    #[test]
    fn autonomous_match_finishes_without_stuck_bots() {
        let mut g = Game::default();
        for _ in 0..24000 {
            g.tick(0.05, false);
            for b in &g.bots {
                assert!(g.map.can_stand(b.pos), "bot inside geometry: {:?}", b.pos);
            }
            if g.phase == Phase::Finished {
                break;
            }
        }
        assert_eq!(g.phase, Phase::Finished);
        assert!(g.scores.iter().any(|s| *s == 5));
        assert!(g.bots.iter().map(|b| b.kills).sum::<u32>() > 0);
    }

    #[test]
    fn spawns_are_separated_and_hidden_at_standing_head_height() {
        let map = Map::default();
        assert_eq!((W, H), (64, 48));
        assert!(map.tiles.iter().flatten().filter(|t| **t == 0).count() > 1800);
        for ct in CT_SPAWNS.into_iter().chain([PLAYER_SPAWN]) {
            for t in T_SPAWNS {
                assert!(ct.distance(t) > 28., "opposing spawns too close");
                // Test multiple points across an operator, not just centre-to-centre.
                for dx in [-0.25, 0., 0.25] {
                    let d = ct.distance(Point::new(t.x + dx, t.z));
                    assert!(
                        map.raycast(
                            [ct.x, 1.75, ct.z],
                            [(t.x + dx - ct.x) / d, 0., (t.z - ct.z) / d],
                            d
                        ) < d - 0.3,
                        "visible opening spawn: {ct:?} -> {t:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn every_bot_route_reaches_both_sites() {
        let mut g = live();
        for site in 0..2 {
            g.bomb.site = site;
            for i in 0..g.bots.len() {
                let mut from = g.bots[i].pos;
                for route in 0..3 {
                    g.bots[i].route = route;
                    let goal = g.route_goal(i);
                    assert!(g.map.can_stand(goal), "route target in cover: {goal:?}");
                    let path = g.map.path(from, goal);
                    assert!(!path.is_empty());
                    assert!(path.iter().all(|p| g.map.can_stand(*p)));
                    from = goal;
                }
            }
        }
    }

    #[test]
    fn fast_raycast_matches_all_geometry_reference() {
        let map = Map::default();
        let reference = |origin: [f32; 3], dir: [f32; 3]| {
            let mut nearest: f32 = 100.;
            for z in 0..H {
                for x in 0..W {
                    if let Some((min, max)) = map.tile_bounds(x, z) {
                        if let Some(t) = ray_box(origin, dir, min, max) {
                            nearest = nearest.min(t);
                        }
                    }
                    for triangle in map.ground_triangles(x, z) {
                        if let Some(t) = terrain::ray_triangle(origin, dir, triangle) {
                            nearest = nearest.min(t);
                        }
                    }
                }
            }
            if dir[1] < -0.0001 {
                nearest = nearest.min(-origin[1] / dir[1]);
            }
            nearest
        };
        let mut seed = 734u32;
        let mut random = || {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            (seed >> 8) as f32 / 16777216.
        };
        for i in 0..2000 {
            let mut origin = [
                random() * (W as f32 + 4.) - 2.,
                0.1 + random() * 5.,
                random() * (H as f32 + 4.) - 2.,
            ];
            if i % 3 == 0 {
                origin[0] = origin[0].floor();
                origin[2] = origin[2].floor();
            }
            let dir = match i % 8 {
                0 => [0., -1., 0.],
                1 => [1., 0., 0.],
                2 => [0., 0., -1.],
                3 => [1., 0., 1.],
                _ => [random() * 2. - 1., random() - 0.5, random() * 2. - 1.],
            };
            let expected = reference(origin, dir);
            let actual = map.raycast(origin, dir, 100.);
            assert!(
                (actual - expected).abs() < 0.001,
                "ray {i}: {origin:?} {dir:?}: {actual} != {expected}"
            );
        }
    }

    #[test]
    fn controlled_taps_are_tighter_than_sustained_fire() {
        let group = |weapon: Weapon, gap: f32| {
            let mut g = live();
            g.weapon = weapon;
            g.map.tiles = [[0; W]; H];
            g.bots.clear();
            let mut error = 0.;
            for _ in 0..10 {
                g.cooldown = 0.;
                g.recover_accuracy(gap);
                assert!(g.fire([32., 10., 8.], [0., 0., 1.], false, false));
                let shot = g.shots.last().unwrap();
                let dx = shot.to[0] - 32.;
                let dy = shot.to[1] - 10.;
                error += dx * dx + dy * dy;
            }
            error
        };
        let taps = group(Weapon::M4, 0.5);
        let spray = group(Weapon::M4, Weapon::M4.spec().interval);
        assert!(spray > taps * 4., "spray {spray}, taps {taps}");
        assert!(group(Weapon::Ak, Weapon::Ak.spec().interval) > spray * 1.5);
    }

    #[test]
    fn accuracy_profiles_reward_aiming_and_recover_with_time() {
        for weapon in [Weapon::M4, Weapon::Ak, Weapon::Awp, Weapon::Deagle] {
            let mut g = live();
            g.weapon = weapon;
            assert!(g.spread(false, true) < g.spread(false, false));
            assert!(g.spread(false, false) < g.spread(true, true));
            let base = g.spread(false, false);
            let o = [g.pos.x, 1.62, g.pos.z];
            assert!(g.fire(o, [0., 0., 1.], false, false));
            let bloom = g.bloom;
            assert!(g.spread(false, false) > base);
            assert!(!g.fire(o, [0., 0., 1.], false, false));
            assert_eq!(g.bloom, bloom, "Rejected shots must not increase spread");
            let mut fine = live();
            fine.weapon = weapon;
            fine.bloom = g.bloom;
            fine.bloom_delay = g.bloom_delay;
            for _ in 0..100 {
                fine.recover_accuracy(0.01);
            }
            g.recover_accuracy(1.);
            assert!(
                (g.bloom - fine.bloom).abs() < 0.00001,
                "Frame-dependent recovery"
            );
            assert_eq!(g.bloom, 0.);
            g.bloom = weapon.accuracy().maximum;
            g.next_round();
            assert_eq!(g.bloom, 0.);
        }
        assert!(Weapon::Awp.accuracy().hip > Weapon::Awp.accuracy().aimed * 50.);
    }

    #[test]
    fn invalid_aim_does_not_consume_ammo() {
        let mut g = live();
        assert!(!g.fire([g.pos.x, 1.62, g.pos.z], [0.; 3], false, false));
        assert!(!g.fire([f32::NAN, 1.62, g.pos.z], [0., 0., 1.], false, false));
        assert_eq!(g.ammo, 30);
        assert_eq!(g.bloom, 0.);
    }
}
