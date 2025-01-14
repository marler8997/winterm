cbuffer GridConfig : register(b0)
{
    uint2 cell_size;
    uint col_count;
    uint row_count;
}

struct Cell
{
    uint glyph_index;
    uint bg;
    uint fg;
    // todo: underline flags, single/double/curly/dotted/dashed
    // todo: underline color
};
StructuredBuffer<Cell> cells : register(t0);
Texture2D<float4> glyph_texture : register(t1);

float4 VertexMain(uint id : SV_VERTEXID) : SV_POSITION
{
    return float4(
        2.0 * (float(id & 1) - 0.5),
        -(float(id >> 1) - 0.5) * 2.0,
        0, 1
    );
}

float4 UnpackRgba(uint packed)
{
    float4 unpacked;
    unpacked.r = (float)((packed >> 24) & 0xFF) / 255.0f;
    unpacked.g = (float)((packed >> 16) & 0xFF) / 255.0f;
    unpacked.b = (float)((packed >> 8) & 0xFF) / 255.0f;
    unpacked.a = (float)(packed & 0xFF) / 255.0f;
    return unpacked;
}

float3 Pixel(float2 pos, float4 bg, float4 fg, float glyph_texel)
{
    float3 cool_rgb_gradient = float3(
        pos.y,
        lerp(0.0, 0.5, pos.x),
        lerp(0.1, 1, 1.0 - (pos.x + pos.y) * 0.5)
    );
    float3 ice_light_gradient = float3(
        lerp(0.75, 0.85, pos.x),  // Subtle ice white to light blue
        lerp(0.85, 0.95, pos.y),  // Very light blue-white gradient
        lerp(1.0, 0.98, (pos.x + pos.y) * 0.5)  // Near-white to ice blue
    );
    float3 ice_dark_gradient = float3(
        lerp(0.05, 0.12, pos.x),  // Deep blue-black to very dark blue
        lerp(0.08, 0.15, pos.y),  // Subtle blue-purple undertones
        lerp(0.2, 0.3, (pos.x + pos.y) * 0.5) // Ice blue accents
    );
    //float3 gradient_bg = cool_rgb_gradient;
    //float3 gradient_bg = ice_light_gradient;
    float3 gradient_bg = ice_dark_gradient;

    // float3 gradient_fg0 = float3(0.3,0.3,0.3);
    // float3 gradient_fg1 = float3(0,0,0);

    float3 gradient_fg0 = float3(0,0,0);
    float3 gradient_fg1 = float3(
        lerp(0.88, 0.9, pos.x),  // Subtle ice white to light blue
        lerp(0.93, 0.99, pos.y),  // Very light blue-white gradient
        lerp(0.98, 1.0, (pos.x + pos.y) * 0.5)  // Near-white to ice blue
    );

    float3 combined_bg = lerp(gradient_bg, bg.rgb, bg.a);
    float3 combined_fg = lerp(gradient_fg0, gradient_fg1, fg.rgb);
    return lerp(combined_bg, combined_fg.rgb, fg.a * glyph_texel);
}

float4 PixelMain(float4 sv_pos : SV_POSITION) : SV_TARGET {
    uint col = sv_pos.x / cell_size.x;
    uint row = sv_pos.y / cell_size.y;
    uint cell_index = row * col_count + col;

    const uint DEBUG_MODE_NONE = 0;
    const uint DEBUG_MODE_GLYPH_TEXTURE = 2;

    const uint DEBUG_MODE = DEBUG_MODE_NONE;
    // const uint DEBUG_MODE = DEBUG_MODE_GLYPH_TEXTURE;

    Cell cell = cells[cell_index];
    float4 bg = UnpackRgba(cell.bg);
    float4 fg = UnpackRgba(cell.fg);

    if (DEBUG_MODE == DEBUG_MODE_GLYPH_TEXTURE) {
        float4 glyph_texel = glyph_texture.Load(int3(sv_pos.xy, 0));
        return lerp(bg, fg, glyph_texel.a);
    }

    uint texture_width, texture_height;
    glyph_texture.GetDimensions(texture_width, texture_height);
    uint2 texture_size = uint2(texture_width, texture_height);
    uint cells_per_row = texture_width / cell_size.x;

    uint2 glyph_cell_pos = uint2(
        cell.glyph_index % cells_per_row,
        cell.glyph_index / cells_per_row
    );
    uint2 cell_pixel = uint2(sv_pos.xy) % cell_size;
    uint2 texture_coord = glyph_cell_pos * cell_size + cell_pixel;
    float4 glyph_texel = glyph_texture.Load(int3(texture_coord, 0));

    float2 pos = sv_pos.xy / (cell_size * float2(col_count, row_count));
    return float4(Pixel(pos, bg, fg, glyph_texel.a), 1.0);
}
