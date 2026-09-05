//! Explicit development build only. Never present in normal player releases.
use bevy::{prelude::*, time::TimeSystems};
use wasm_bindgen::prelude::*;

#[wasm_bindgen(
    inline_js = "export function dustline_capture_delta() { const c = window.__dustlineCapture; if (!c) return -1; const dt = c.delta || 0; c.delta = 0; if (dt > 0) c.applied = c.request; return dt; }"
)]
extern "C" {
    fn dustline_capture_delta() -> f64;
}

#[derive(Resource, Default)]
struct Step(Option<std::time::Duration>);

pub fn install(app: &mut App) {
    app.init_resource::<Step>()
        .add_systems(First, prepare.before(TimeSystems))
        .add_systems(First, advance.after(TimeSystems));
}

fn prepare(mut virtual_time: ResMut<Time<Virtual>>, mut step: ResMut<Step>) {
    let delta = dustline_capture_delta();
    step.0 = (delta >= 0.).then(|| std::time::Duration::from_secs_f64(delta.clamp(0., 0.25)));
    if step.0.is_some() {
        virtual_time.pause();
    } else {
        virtual_time.unpause();
    }
}

fn advance(
    mut virtual_time: ResMut<Time<Virtual>>,
    mut game_time: ResMut<Time>,
    step: Res<Step>,
    mut session: ResMut<crate::Session>,
) {
    if let Some(delta) = step.0 {
        // Keep Time<Real> and browser scheduling real. Only gameplay time is
        // stepped; freezing the renderer's own clock can stall capture hosts.
        virtual_time.advance_by(delta);
        *game_time = virtual_time.as_generic();
        session.hud_timer = 0.;
    }
}
