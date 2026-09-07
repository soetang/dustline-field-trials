//! Small, reusable material helpers. Texture density is measured in world metres.
use bevy::{
    asset::RenderAssetUsages,
    image::{ImageAddressMode, ImageLoaderSettings, ImageSampler, ImageSamplerDescriptor},
    mesh::{Indices, PrimitiveTopology, VertexAttributeValues},
    prelude::*,
};

pub fn ground_mesh(map: &crate::rules::Map) -> Mesh {
    let mut positions = Vec::new();
    let mut normals = Vec::new();
    for z in 0..crate::rules::H {
        for x in 0..crate::rules::W {
            for triangle in map.ground_triangles(x, z) {
                for p in triangle {
                    positions.push(p);
                    let dx = map.elevation(p[0] + 0.25, p[2]) - map.elevation(p[0] - 0.25, p[2]);
                    let dz = map.elevation(p[0], p[2] + 0.25) - map.elevation(p[0], p[2] - 0.25);
                    normals.push(Vec3::new(-dx, 0.5, -dz).normalize().to_array());
                }
            }
        }
    }
    let indices: Vec<u32> = (0..positions.len() as u32).collect();
    let mut mesh = Mesh::new(
        PrimitiveTopology::TriangleList,
        RenderAssetUsages::default(),
    )
    .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)
    .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, normals)
    .with_inserted_indices(Indices::U32(indices));
    world_uv(&mut mesh, 2.1);
    mesh
}

pub fn concrete(assets: &AssetServer, name: &str, tint: Color) -> StandardMaterial {
    let load = |suffix: &str, is_srgb: bool| {
        assets
            .load_builder()
            .with_settings(move |settings: &mut ImageLoaderSettings| {
                settings.is_srgb = is_srgb;
                settings.sampler = ImageSampler::Descriptor(ImageSamplerDescriptor {
                    address_mode_u: ImageAddressMode::Repeat,
                    address_mode_v: ImageAddressMode::Repeat,
                    anisotropy_clamp: 4,
                    ..ImageSamplerDescriptor::linear()
                });
            })
            .load(format!("textures/{name}_{suffix}_1k.jpg"))
    };
    let arm = load("arm", false);
    StandardMaterial {
        base_color: tint,
        base_color_texture: Some(load("diff", true)),
        normal_map_texture: Some(load("nor_gl", false)),
        metallic_roughness_texture: Some(arm.clone()),
        occlusion_texture: Some(arm),
        // ARM is R=occlusion, G=roughness, B=metallic. Scalars multiply those maps.
        metallic: 1.,
        perceptual_roughness: 1.,
        reflectance: 0.35,
        ..default()
    }
}

pub fn world_uv(mesh: &mut Mesh, metres_per_repeat: f32) {
    let Some(VertexAttributeValues::Float32x3(positions)) =
        mesh.attribute(Mesh::ATTRIBUTE_POSITION)
    else {
        return;
    };
    let Some(VertexAttributeValues::Float32x3(normals)) = mesh.attribute(Mesh::ATTRIBUTE_NORMAL)
    else {
        return;
    };
    let uvs: Vec<[f32; 2]> = positions
        .iter()
        .zip(normals)
        .map(|(p, n)| {
            let uv = if n[1].abs() > 0.5 {
                [p[0], p[2]]
            } else if n[0].abs() > 0.5 {
                [p[2], -p[1]]
            } else {
                [p[0], -p[1]]
            };
            [uv[0] / metres_per_repeat, uv[1] / metres_per_repeat]
        })
        .collect();
    mesh.insert_attribute(Mesh::ATTRIBUTE_UV_0, uvs);
    mesh.generate_tangents()
        .expect("Arena meshes have triangle normals and valid UVs");
}
