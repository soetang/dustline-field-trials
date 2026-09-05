//! Shared placement data lets fast tests check decorative supports without a GPU.
pub const PILLAR_SIZE: [f32; 3] = [0.32, 2.7, 0.32];
pub const CT_PILLARS: [[f32; 3]; 2] = [[26.6, 1.35, 16.], [37.4, 1.35, 16.]];
pub const LINTEL_SIZE: [f32; 3] = [11.1, 0.32, 0.42];
pub const CT_LINTEL: [f32; 3] = [32., 2.55, 16.];
pub const LAMP_SIZE: [f32; 3] = [0.22, 0.32, 0.14];
// Centre and outward-facing Z direction. The first two attach to the CT gate;
// the third attaches to B site's north wall, not empty corridor air.
pub const LAMPS: [([f32; 3], f32); 3] = [
    ([26.6, 2., 15.80], -1.),
    ([37.4, 2., 15.80], -1.),
    ([super::SITES[1].x, 2., 4.05], 1.),
];

#[cfg(test)]
mod tests {
    use super::super::Map;
    use super::*;

    #[test]
    fn every_lamp_is_mounted_on_a_grounded_pillar_or_wall() {
        let map = Map::default();
        for pillar in CT_PILLARS {
            let foot = pillar[1] - PILLAR_SIZE[1] / 2.;
            let ground = map.elevation(pillar[0], pillar[2]);
            // Foundations may enter a gentle slope, but must never hang above
            // it (or disappear deeply beneath it).
            assert!(foot <= ground + 0.001 && foot >= ground - 0.2);
            assert!((pillar[0] - CT_LINTEL[0]).abs() < LINTEL_SIZE[0] / 2.);
            assert!(pillar[1] + PILLAR_SIZE[1] / 2. > CT_LINTEL[1] - LINTEL_SIZE[1] / 2.);
        }
        for (position, facing) in LAMPS {
            let back = [
                position[0],
                position[1],
                position[2] - facing * LAMP_SIZE[2] / 2.,
            ];
            let on_pillar = CT_PILLARS.iter().any(|pillar| {
                (0..3).all(|axis| (back[axis] - pillar[axis]).abs() <= PILLAR_SIZE[axis] / 2.)
            });
            let (x, z) = (back[0].floor() as usize, back[2].floor() as usize);
            let on_wall = map.tiles[z][x] == 1
                && map.tile_bounds(x, z).is_some_and(|(min, max)| {
                    (0..3).all(|axis| back[axis] >= min[axis] && back[axis] <= max[axis])
                });
            assert!(on_pillar || on_wall, "Unsupported lamp at {position:?}");
            let front_z = position[2] + facing * (LAMP_SIZE[2] / 2. + 0.01);
            assert!(
                !map.solid(position[0], front_z),
                "Lamp face is buried in architecture"
            );
        }
    }
}
