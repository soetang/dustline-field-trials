//! A low-cost desert backdrop: a gradient sky and batched sandstone ridges.
use super::*;
use bevy::{
    asset::RenderAssetUsages,
    mesh::{PrimitiveTopology, VertexAttributeValues},
};

pub fn spawn(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
) {
    let center = Vec3::new(MAP_W as f32 / 2., -3., MAP_H as f32 / 2.);
    let mut positions = Vec::new();
    let mut colours = Vec::new();
    for ring in 0..12 {
        for sector in 0..64 {
            for (r, s) in [
                (ring, sector),
                (ring + 1, sector),
                (ring, sector + 1),
                (ring, sector + 1),
                (ring + 1, sector),
                (ring + 1, sector + 1),
            ] {
                let elevation = r as f32 / 12. * FRAC_PI_2;
                let angle = s as f32 / 64. * 2. * PI;
                positions.push(
                    (center
                        + Vec3::new(
                            angle.cos() * elevation.cos(),
                            elevation.sin(),
                            angle.sin() * elevation.cos(),
                        ) * 190.)
                        .to_array(),
                );
                let t = elevation.sin().powf(0.55);
                colours.push(
                    Color::srgb(0.72 - 0.48 * t, 0.76 - 0.31 * t, 0.73 - 0.10 * t)
                        .to_linear()
                        .to_f32_array(),
                );
            }
        }
    }
    let count = positions.len();
    let sky = Mesh::new(
        PrimitiveTopology::TriangleList,
        RenderAssetUsages::default(),
    )
    .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)
    .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, vec![[0., -1., 0.]; count])
    .with_inserted_attribute(Mesh::ATTRIBUTE_COLOR, colours);
    commands.spawn((
        Mesh3d(meshes.add(sky)),
        MeshMaterial3d(materials.add(StandardMaterial {
            unlit: true,
            fog_enabled: false,
            cull_mode: None,
            ..default()
        })),
        Transform::default(),
        NotShadowCaster,
    ));
    let sand = materials.add(StandardMaterial {
        base_color: Color::srgb(0.5, 0.37, 0.23),
        perceptual_roughness: 1.,
        ..default()
    });
    commands.spawn((
        Mesh3d(meshes.add(Cuboid::new(180., 0.2, 160.))),
        MeshMaterial3d(sand.clone()),
        Transform::from_xyz(center.x, -0.18, center.z),
    ));
    let mut ridge: Option<Mesh> = None;
    for edge in 0..4 {
        for i in 0..12 {
            let n = (i * 29 + edge * 17) as f32;
            let tall = 4. + (n * 1.73).sin().abs() * 8.;
            let along = i as f32 * 7.5 - 10.;
            let p = match edge {
                0 => Vec3::new(along, tall * 0.25, -10. - (n * 0.8).sin().abs() * 8.),
                1 => Vec3::new(
                    along,
                    tall * 0.25,
                    MAP_H as f32 + 10. + (n * 0.8).sin().abs() * 8.,
                ),
                2 => Vec3::new(-12. - (n * 0.8).sin().abs() * 8., tall * 0.25, along),
                _ => Vec3::new(
                    MAP_W as f32 + 12. + (n * 0.8).sin().abs() * 8.,
                    tall * 0.25,
                    along,
                ),
            };
            let mut mesh = Sphere::new(1.)
                .mesh()
                .ico(1)
                .expect("Valid low-poly rock subdivision");
            if let Some(VertexAttributeValues::Float32x3(vertices)) =
                mesh.attribute_mut(Mesh::ATTRIBUTE_POSITION)
            {
                for v in vertices {
                    let wobble = 1. + (v[0] * 13. + v[2] * 9. + n).sin() * 0.17;
                    v[0] *= wobble;
                    v[2] *= wobble;
                }
            }
            mesh = mesh.transformed_by(
                Transform::from_translation(p)
                    .with_scale(Vec3::new(5. + (n * 0.4).sin().abs() * 3., tall, 5.5))
                    .with_rotation(Quat::from_rotation_y(n)),
            );
            if let Some(combined) = &mut ridge {
                combined.merge(&mesh).expect("Matching rock vertex formats");
            } else {
                ridge = Some(mesh);
            }
        }
    }
    if let Some(mut mesh) = ridge {
        mesh.duplicate_vertices();
        mesh.compute_flat_normals();
        commands.spawn((
            Mesh3d(meshes.add(mesh)),
            MeshMaterial3d(sand),
            Transform::default(),
        ));
    }
}
