#define WAVE_MATRIX_DIM 16
#define WAVE_SIZE 32


cbuffer cb0 : register(b0)
{
    uint Width;
    uint Height;
    uint InputTextureOffset;
    uint OutputTextureOffset;
};
// 需要用preview版本的dxc
// 不能链接dxil.dll 还是说要用别的版本的dxil
// 用最新的release dxil.dll 会报错误？

#define TILE_SIZE 16

// Shared Memory
groupshared float16_t groupMatInput_x[TILE_SIZE * TILE_SIZE];
groupshared float16_t groupMatInput_y[TILE_SIZE * TILE_SIZE];
groupshared float16_t groupMatInput_z[TILE_SIZE * TILE_SIZE];
groupshared float16_t groupMatWeight[TILE_SIZE * TILE_SIZE];
groupshared float16_t groupMatOutput_x[TILE_SIZE * TILE_SIZE];
groupshared float16_t groupMatOutput_y[TILE_SIZE * TILE_SIZE];
groupshared float16_t groupMatOutput_z[TILE_SIZE * TILE_SIZE];

// 每个group只有一个wave
// 每个group处理一个16x16 tile
[wavesize(WAVE_SIZE)]
[numthreads(32, 1, 1)]
void CSMain(
    uint2 groupTheadId : SV_GroupThreadID,
    uint2 groupId : SV_GroupID,
    uint groupIndex : SV_GroupIndex
    )
{
    Texture2D InputTexture = ResourceDescriptorHeap[InputTextureOffset];
    RWTexture2D<float4> OutputTexture = ResourceDescriptorHeap[OutputTextureOffset];
    const uint LoopNum = 4;
    for (int i = 0; i < LoopNum; i++){
        for (int j = 0; j < 2; j++){
            uint2 PixelPos = groupId * uint2(TILE_SIZE, TILE_SIZE) + 
                uint2(2 * (WaveGetLaneIndex() % 8) + j, LoopNum * 4 + WaveGetLaneIndex() / 8);

            float4 Color = (0.f).xxxx;
            
            if (all(PixelPos < uint2(Width, Height)))
                Color = InputTexture[PixelPos];

            uint SharedArrayIndex = j + WaveGetLaneIndex() * 2 + LoopNum * 64;
            groupMatInput_x[SharedArrayIndex] = (float16_t)Color.x;
            groupMatInput_y[SharedArrayIndex] = (float16_t)Color.y;
            groupMatInput_z[SharedArrayIndex] = (float16_t)Color.z;

            groupMatWeight[SharedArrayIndex] = (float16_t)(1.f / 16.f);
        }
    }

    // Define the Wave Wide Matrices
    WaveMatrixLeft <float16_t, 16, 16> matA_x;
    WaveMatrixLeft <float16_t, 16, 16> matA_y;
    WaveMatrixLeft <float16_t, 16, 16> matA_z;
    WaveMatrixRight <float16_t, 16, 16> matB;
    WaveMatrixAccumulator <float16_t, 16, 16> matC_x;
    WaveMatrixAccumulator <float16_t, 16, 16> matC_y;
    WaveMatrixAccumulator <float16_t, 16, 16> matC_z;

    // uint matrixDepth =  matA_x.GetWaveMatrixDepth();// Returns K must be a multiple of 16
    matC_x.Fill(0);
    matC_y.Fill(0);
    matC_z.Fill(0);

    matB.Load(groupMatWeight, 0, 16, false);
    {
        matA_x.Load(groupMatInput_x, 0, 16, false);
        matA_y.Load(groupMatInput_y, 0, 16, false);
        matA_z.Load(groupMatInput_z, 0, 16, false);

        matC_x.MultiplyAccumulate(matA_x, matB);
        matC_y.MultiplyAccumulate(matA_y, matB);
        matC_z.MultiplyAccumulate(matA_z, matB);
    }

    matC_x.Store(groupMatOutput_x, 0, 16, false);
    matC_y.Store(groupMatOutput_y, 0, 16, false);
    matC_z.Store(groupMatOutput_z, 0, 16, false);
    
    for (int i = 0; i < LoopNum; i++){
        for (int j = 0; j < 2; j++){
            uint2 PixelPos = groupId * uint2(TILE_SIZE, TILE_SIZE) + 
                uint2(2 * (WaveGetLaneIndex() % 8) + j, LoopNum * 4 + WaveGetLaneIndex() / 8);

            if (any(PixelPos >= uint2(Width, Height)))
                continue;
            uint SharedArrayIndex = j + WaveGetLaneIndex() * 2 + LoopNum * 64;
            float4 Result = float4( groupMatOutput_x[SharedArrayIndex], 
                                    groupMatOutput_y[SharedArrayIndex], 
                                    groupMatOutput_z[SharedArrayIndex], 1.f);
            
            OutputTexture[PixelPos] = Result;
        }
    }
    
}