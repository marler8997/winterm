cbuffer GridConfig : register(b0)
{
    uint2 cell_size;
    uint col_count;
    uint row_count;
}

struct Cell
{
    uint glyph_index;
    uint background;
    uint foreground;
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

float4 PixelMain(float4 sv_pos : SV_POSITION) : SV_TARGET {
    uint2 grid_pos = sv_pos.xy / cell_size;
    uint index = grid_pos.y * col_count + grid_pos.x;

    const uint DEBUG_MODE_NONE = 0;
    const uint DEBUG_MODE_CHECKERBOARD = 1;
    const uint DEBUG_MODE_GLYPH_TEXTURE = 2;

    const uint DEBUG_MODE = DEBUG_MODE_NONE;
    //const uint DEBUG_MODE = DEBUG_MODE_CHECKERBOARD;
    //const uint DEBUG_MODE = DEBUG_MODE_GLYPH_TEXTURE;

    if (DEBUG_MODE == DEBUG_MODE_CHECKERBOARD) {
        uint cell_count = col_count * row_count;
        float strength = float(index) / float(cell_count);
        uint checker = (grid_pos.x + grid_pos.y) % 2;
        if (checker == 0) {
            float shade = 1.0 - strength;
            return float4(shade,shade,shade,1);
        }
        return float4(0,0,0,1);
    }

    Cell cell = cells[index];
    float4 cell_bg_color = UnpackRgba(cell.background);
    float4 fg_color = UnpackRgba(cell.foreground);

    if (DEBUG_MODE == DEBUG_MODE_GLYPH_TEXTURE) {
        float4 glyph_texel = glyph_texture.Load(int3(sv_pos.xy, 0));
        return lerp(cell_bg_color, fg_color, glyph_texel);
    }

    uint2 cell_pixel = uint2(sv_pos.xy) % cell_size;

    uint texture_width, texture_height;
    glyph_texture.GetDimensions(texture_width, texture_height);
    uint2 texture_size = uint2(texture_width, texture_height);
    uint cells_per_row = texture_width / cell_size.x;

    uint2 glyph_cell_pos = uint2(
        cell.glyph_index % cells_per_row,
        cell.glyph_index / cells_per_row
    );
    uint2 texture_coord = glyph_cell_pos * cell_size + cell_pixel;
    float4 glyph_texel = glyph_texture.Load(int3(texture_coord, 0));
    float3 cool_rgb_gradient = float3(
        sv_pos.x / (cell_size.x * col_count),  // R increases from left to right
        sv_pos.y / (cell_size.y * row_count),  // G increases from top to bottom
        1.0 - (sv_pos.x + sv_pos.y) / (cell_size.x * col_count + cell_size.y * row_count)  // B complement of R+G
    );
    float3 ice_light_gradient = float3(
        lerp(0.8, 0.9, sv_pos.x / (cell_size.x * col_count)),  // Subtle ice white to light blue
        lerp(0.85, 0.95, sv_pos.y / (cell_size.y * row_count)),  // Very light blue-white gradient
        lerp(1.0, 0.98, (sv_pos.x + sv_pos.y) / (cell_size.x * col_count + cell_size.y * row_count))  // Near-white to ice blue
    );
    float3 ice_dark_gradient = float3(
        lerp(0.05, 0.12, sv_pos.x / (cell_size.x * col_count)),  // Deep blue-black to very dark blue
        lerp(0.08, 0.15, sv_pos.y / (cell_size.y * row_count)),  // Subtle blue-purple undertones
        lerp(0.2, 0.25, (sv_pos.x + sv_pos.y) / (cell_size.x * col_count + cell_size.y * row_count))  // Ice blue accents
    );

    float3 combined_bg_color = lerp(ice_dark_gradient, cell_bg_color.rgb, cell_bg_color.a);
    return lerp(float4(combined_bg_color, 1.0), fg_color, glyph_texel.a);
}
