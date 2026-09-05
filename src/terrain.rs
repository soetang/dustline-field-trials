//! Authored gentle terrain. Rendering, actor heights and bullet collision share
//! the same two triangles per metre, so visible slopes cannot hide a flat floor.

fn vertex_height(x: f32, z: f32) -> f32 {
    [
        (8., 27., 6., 10., 1.6),
        (53., 29., 7., 11., 1.1),
        (34., 21., 6., 7., 0.65),
    ]
    .into_iter()
    .map(|(cx, cz, rx, rz, height)| {
        let radius = ((x - cx) / rx).powi(2) + ((z - cz) / rz).powi(2);
        height * (1. - radius).max(0.).powi(2)
    })
    .sum()
}

pub fn elevation(x: f32, z: f32) -> f32 {
    let (ix, iz) = (x.floor(), z.floor());
    let (u, v) = (x - ix, z - iz);
    let h00 = vertex_height(ix, iz);
    let h10 = vertex_height(ix + 1., iz);
    let h01 = vertex_height(ix, iz + 1.);
    let h11 = vertex_height(ix + 1., iz + 1.);
    if u + v <= 1. {
        h00 + (h10 - h00) * u + (h01 - h00) * v
    } else {
        h11 + (h01 - h11) * (1. - u) + (h10 - h11) * (1. - v)
    }
}

#[cfg(test)]
pub fn triangles(x: i32, z: i32) -> [[[f32; 3]; 3]; 2] {
    let (x, z) = (x as f32, z as f32);
    let a = [x, vertex_height(x, z), z];
    let b = [x + 1., vertex_height(x + 1., z), z];
    let c = [x, vertex_height(x, z + 1.), z + 1.];
    let d = [x + 1., vertex_height(x + 1., z + 1.), z + 1.];
    [[a, c, b], [b, c, d]]
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

pub fn ray_triangle(origin: [f32; 3], direction: [f32; 3], triangle: [[f32; 3]; 3]) -> Option<f32> {
    let e1 = sub(triangle[1], triangle[0]);
    let e2 = sub(triangle[2], triangle[0]);
    let p = cross(direction, e2);
    let determinant = dot(e1, p);
    if determinant.abs() < 0.000001 {
        return None;
    }
    let inverse = determinant.recip();
    let offset = sub(origin, triangle[0]);
    let u = dot(offset, p) * inverse;
    if !(-0.00001..=1.00001).contains(&u) {
        return None;
    }
    let q = cross(offset, e1);
    let v = dot(direction, q) * inverse;
    if v < -0.00001 || u + v > 1.00001 {
        return None;
    }
    let distance = dot(e2, q) * inverse;
    (distance >= 0.).then_some(distance)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hills_have_walkable_grades_and_flat_spawns() {
        assert!(elevation(8., 27.) > 1.5);
        assert!(elevation(53., 29.) > 1.);
        for (x, z) in [
            (32.4, 7.6),
            (30.2, 7.),
            (36.6, 10.4),
            (28.2, 40.4),
            (35., 39.),
        ] {
            assert_eq!(elevation(x, z), 0.);
        }
        for z in 0..48 {
            for x in 0..64 {
                let h = elevation(x as f32, z as f32);
                assert!((0. ..=1.7).contains(&h));
                assert!((h - elevation(x as f32 + 1., z as f32)).abs() <= 0.42);
                assert!((h - elevation(x as f32, z as f32 + 1.)).abs() <= 0.42);
            }
        }
    }

    #[test]
    fn actor_height_matches_rendered_triangle_and_bullet_hit() {
        for z in 0..48 {
            for x in 0..64 {
                for (u, v) in [(0., 0.), (0.2, 0.3), (0.7, 0.8), (1., 1.)] {
                    let px = x as f32 + u;
                    let pz = z as f32 + v;
                    let hit = triangles(x, z)
                        .into_iter()
                        .filter_map(|t| ray_triangle([px, 5., pz], [0., -1., 0.], t))
                        .reduce(f32::min)
                        .unwrap();
                    assert!((5. - hit - elevation(px, pz)).abs() < 0.00001);
                }
            }
        }
    }

    #[test]
    fn hills_block_low_horizontal_shots_but_not_shots_above_them() {
        let ray = |height| {
            (15..40)
                .flat_map(|z| triangles(8, z))
                .filter_map(|triangle| ray_triangle([8.5, height, 15.], [0., 0., 1.], triangle))
                .reduce(f32::min)
        };
        assert!(ray(0.8).is_some());
        assert!(ray(2.).is_none());
    }
}
