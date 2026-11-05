//! Draws a list of primitives with wgpu: rectangles with rounded corners or
//! outlines, glyphs from an atlas, and wavy lines, as one instanced quad
//! each, in the order given.
use std::sync::Arc;

/// One primitive, in screen pixels.
#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Instance {
    pub rect: [f32; 4],
    pub uv: [f32; 4],
    pub color: [f32; 4],
    /// Kind, corner radius, line thickness.
    pub params: [f32; 4],
    /// Left, top, right and bottom of where it may show.
    pub clip: [f32; 4],
}
/// No clipping.
pub const UNCLIPPED: [f32; 4] = [f32::MIN, f32::MIN, f32::MAX, f32::MAX];
pub const RECT: f32 = 0.0;
pub const MASK: f32 = 1.0;
pub const COLOR: f32 = 2.0;
pub const WAVE: f32 = 3.0;
pub const OUTLINE: f32 = 4.0;

/// Room for glyph images, filled shelf by shelf.
pub struct Atlas {
    pub size: u32,
    shelf_x: u32,
    shelf_y: u32,
    shelf_height: u32,
    /// Images waiting to be copied to the texture: where, and their pixels.
    pending: Vec<([u32; 4], Vec<u8>)>,
    /// Whether everything was dropped to make room; glyphs place again.
    pub cleared: bool,
}
impl Atlas {
    fn new(size: u32) -> Self {
        Self {
            size,
            shelf_x: 0,
            shelf_y: 0,
            shelf_height: 0,
            pending: vec![],
            cleared: false,
        }
    }
    /// Places an RGBA image; none when the atlas is full.
    pub fn place(&mut self, width: u32, height: u32, rgba: Vec<u8>) -> Option<[u32; 4]> {
        // A pixel of space around each image keeps sampling to its own.
        let (w, h) = (width + 1, height + 1);
        if w > self.size || h > self.size {
            return None;
        }
        if self.shelf_x + w > self.size {
            self.shelf_y += self.shelf_height;
            self.shelf_x = 0;
            self.shelf_height = 0;
        }
        if self.shelf_y + h > self.size {
            return None;
        }
        let place = [self.shelf_x, self.shelf_y, width, height];
        self.shelf_x += w;
        self.shelf_height = self.shelf_height.max(h);
        self.pending.push((place, rgba));
        Some(place)
    }
    /// Drops every image, to start filling again.
    pub fn clear(&mut self) {
        self.shelf_x = 0;
        self.shelf_y = 0;
        self.shelf_height = 0;
        self.pending.clear();
        self.cleared = true;
    }
}

/// Where frames go: a window, or a texture to read back.
enum Target {
    Window {
        window: Arc<winit::window::Window>,
        surface: wgpu::Surface<'static>,
        config: wgpu::SurfaceConfiguration,
    },
    Texture {
        texture: wgpu::Texture,
        width: u32,
        height: u32,
    },
}
pub struct Renderer {
    target: Target,
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    uniforms: wgpu::Buffer,
    bindings: wgpu::BindGroup,
    texture: wgpu::Texture,
    instances: wgpu::Buffer,
    capacity: usize,
    pub atlas: Atlas,
    /// How glyph coverage is corrected: `gamma_ratios` and the contrast.
    text: [f32; 8],
}
const ATLAS_SIZE: u32 = 2048;
impl Renderer {
    /// A renderer drawing into a window.
    pub fn new(window: Arc<winit::window::Window>) -> Result<Self, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let surface = instance
            .create_surface(window.clone())
            .map_err(|error| error.to_string())?;
        let (adapter, device, queue) = Self::device(&instance, Some(&surface))?;
        let size = window.inner_size();
        let mut config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .ok_or("the window's surface cannot be drawn on")?;
        // Colors blend as written, as terminals blend them, rather than in
        // linear light, which thins text.
        let formats = surface.get_capabilities(&adapter).formats;
        if let Some(format) = formats.iter().find(|format| !format.is_srgb()) {
            config.format = *format;
        }
        config.present_mode = wgpu::PresentMode::AutoVsync;
        surface.configure(&device, &config);
        let format = config.format;
        let target = Target::Window {
            window,
            surface,
            config,
        };
        Ok(Self::build(device, queue, format, target))
    }
    /// A renderer drawing into a texture of this size, read back with
    /// `read`; it needs no window.
    pub fn offscreen(width: u32, height: u32) -> Result<Self, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let (_, device, queue) = Self::device(&instance, None)?;
        let format = wgpu::TextureFormat::Rgba8Unorm;
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("frame"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let target = Target::Texture {
            texture,
            width,
            height,
        };
        Ok(Self::build(device, queue, format, target))
    }
    fn device(
        instance: &wgpu::Instance,
        surface: Option<&wgpu::Surface<'_>>,
    ) -> Result<(wgpu::Adapter, wgpu::Device, wgpu::Queue), String> {
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::LowPower,
            compatible_surface: surface,
            ..Default::default()
        }))
        .map_err(|error| error.to_string())?;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("soda"),
            ..Default::default()
        }))
        .map_err(|error| error.to_string())?;
        Ok((adapter, device, queue))
    }
    fn build(
        device: wgpu::Device,
        queue: wgpu::Queue,
        format: wgpu::TextureFormat,
        target: Target,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("soda"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });
        let uniforms = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("screen"),
            size: 48,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("atlas"),
            size: wgpu::Extent3d {
                width: ATLAS_SIZE,
                height: ATLAS_SIZE,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("soda"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let bindings = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("soda"),
            layout: &layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: uniforms.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&sampler),
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("soda"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let attributes = wgpu::vertex_attr_array![
            0 => Float32x4, 1 => Float32x4, 2 => Float32x4, 3 => Float32x4, 4 => Float32x4
        ];
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("soda"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vertex"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Instance>() as u64,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &attributes,
                })],
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fragment"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let capacity = 4096;
        let instances = Self::buffer(&device, capacity);
        Self {
            target,
            device,
            queue,
            pipeline,
            uniforms,
            bindings,
            texture,
            instances,
            capacity,
            atlas: Atlas::new(ATLAS_SIZE),
            text: text_correction(1.8, 1.0),
        }
    }
    fn buffer(device: &wgpu::Device, capacity: usize) -> wgpu::Buffer {
        device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("instances"),
            size: (capacity * std::mem::size_of::<Instance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        })
    }
    /// The window drawn into, if it is one.
    pub fn window(&self) -> Option<&Arc<winit::window::Window>> {
        match &self.target {
            Target::Window { window, .. } => Some(window),
            Target::Texture { .. } => None,
        }
    }
    pub fn resize(&mut self, width: u32, height: u32) {
        if let Target::Window {
            surface, config, ..
        } = &mut self.target
        {
            config.width = width.max(1);
            config.height = height.max(1);
            surface.configure(&self.device, config);
        }
    }
    /// The size of the frame in pixels.
    pub fn size(&self) -> (u32, u32) {
        match &self.target {
            Target::Window { config, .. } => (config.width, config.height),
            Target::Texture { width, height, .. } => (*width, *height),
        }
    }
    /// Draws a frame over `background`.
    /// Sets how glyphs' coverage is corrected: the gamma it is tuned for,
    /// 1.0 to 2.2, and how much dark text is thickened, 0 for none.
    pub fn set_text(&mut self, gamma: f32, contrast: f32) {
        self.text = text_correction(gamma, contrast);
    }
    pub fn draw(&mut self, background: [f32; 4], instances: &[Instance]) {
        for (place, rgba) in self.atlas.pending.drain(..) {
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &self.texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d {
                        x: place[0],
                        y: place[1],
                        z: 0,
                    },
                    aspect: wgpu::TextureAspect::All,
                },
                &rgba,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(place[2] * 4),
                    rows_per_image: Some(place[3]),
                },
                wgpu::Extent3d {
                    width: place[2],
                    height: place[3],
                    depth_or_array_layers: 1,
                },
            );
        }
        let (frame, view) = match &self.target {
            Target::Window {
                window,
                surface,
                config,
            } => match surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(frame)
                | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => {
                    let view = frame
                        .texture
                        .create_view(&wgpu::TextureViewDescriptor::default());
                    (Some(frame), view)
                }
                wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                    surface.configure(&self.device, config);
                    window.request_redraw();
                    return;
                }
                _ => return,
            },
            Target::Texture { texture, .. } => (
                None,
                texture.create_view(&wgpu::TextureViewDescriptor::default()),
            ),
        };
        let (width, height) = self.size();
        if instances.len() > self.capacity {
            self.capacity = instances.len().next_power_of_two();
            self.instances = Self::buffer(&self.device, self.capacity);
        }
        self.queue
            .write_buffer(&self.instances, 0, bytemuck::cast_slice(instances));
        let t = self.text;
        let screen = [
            width as f32,
            height as f32,
            ATLAS_SIZE as f32,
            ATLAS_SIZE as f32,
            t[0],
            t[1],
            t[2],
            t[3],
            t[4],
            0.0,
            0.0,
            0.0,
        ];
        self.queue
            .write_buffer(&self.uniforms, 0, bytemuck::cast_slice(&screen));
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("soda"),
            });
        {
            let [r, g, b, a] = background.map(f64::from);
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("soda"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            if !instances.is_empty() {
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &self.bindings, &[]);
                pass.set_vertex_buffer(0, self.instances.slice(..));
                pass.draw(0..6, 0..instances.len() as u32);
            }
        }
        self.queue.submit([encoder.finish()]);
        if let (Some(frame), Some(window)) = (frame, self.window()) {
            window.pre_present_notify();
            self.queue.present(frame);
        }
    }
    /// The last frame drawn offscreen, as rows of RGBA pixels.
    pub fn read(&self) -> Option<Vec<u8>> {
        let Target::Texture {
            texture,
            width,
            height,
        } = &self.target
        else {
            return None;
        };
        // Rows of a copy are padded to a multiple of 256 bytes.
        let row = (width * 4).div_ceil(256) * 256;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: u64::from(row * height),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("readback"),
            });
        encoder.copy_texture_to_buffer(
            texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(*height),
                },
            },
            wgpu::Extent3d {
                width: *width,
                height: *height,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit([encoder.finish()]);
        let slice = buffer.slice(..);
        let (sender, receiver) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        receiver.recv().ok()?.ok()?;
        let data = slice.get_mapped_range().ok()?;
        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        for y in 0..*height {
            let start = (y * row) as usize;
            pixels.extend_from_slice(&data[start..start + (width * 4) as usize]);
        }
        Some(pixels)
    }
}

/// The coverage correction of glyphs as DirectWrite makes it for blending
/// that is not gamma correct, as Zed takes it: the ratios for the gamma
/// nearest `gamma`, scaled to coverage and color in 0 to 1, then the
/// contrast.
fn text_correction(gamma: f32, contrast: f32) -> [f32; 8] {
    const RATIOS: [[f32; 4]; 13] = [
        [0.0000, 0.0000, 0.0000, 0.0000],
        [0.0166, -0.0807, 0.2227, -0.0751],
        [0.0350, -0.1760, 0.4325, -0.1370],
        [0.0543, -0.2821, 0.6302, -0.1876],
        [0.0739, -0.3963, 0.8167, -0.2287],
        [0.0933, -0.5161, 0.9926, -0.2616],
        [0.1121, -0.6395, 1.1588, -0.2877],
        [0.1300, -0.7649, 1.3159, -0.3080],
        [0.1469, -0.8911, 1.4644, -0.3234],
        [0.1627, -1.0170, 1.6051, -0.3347],
        [0.1773, -1.1420, 1.7385, -0.3426],
        [0.1908, -1.2652, 1.8650, -0.3476],
        [0.2031, -1.3864, 1.9851, -0.3501],
    ];
    let norm13 = (0x10000 as f64 / (255.0 * 255.0) * 4.0) as f32 / 4.0;
    let norm24 = (0x100 as f64 / 255.0 * 4.0) as f32 / 4.0;
    let index = ((gamma * 10.0).round() as usize).clamp(10, 22) - 10;
    let r = RATIOS[index];
    [
        r[0] * norm13,
        r[1] * norm24,
        r[2] * norm13,
        r[3] * norm24,
        contrast.max(0.0),
        0.0,
        0.0,
        0.0,
    ]
}
