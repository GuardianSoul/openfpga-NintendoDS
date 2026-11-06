import copy,hashlib,json
SCHEMA='nds-clean-gx-atomic-v1'
TARGET='355a2021'
VERTEX = {'Position': ('i', 4), 'Color': ('i', 3), 'TexCoords': ('h', 2),
          'Clipped': ('?', 1), 'FinalPosition': ('i', 2),
          'FinalColor': ('i', 3), 'HiresPosition': ('i', 2)}
POLYGON = {n: ('I', 1) for n in ['NumVertices', 'Attr', 'TexParam', 'TexPalette',
                               'VTop', 'VBottom', 'SortKey']}
POLYGON.update({n: ('i', 1) for n in ['Type', 'YTop', 'YBottom', 'XTop', 'XBottom']})
POLYGON.update({n: ('?', 1) for n in ['WBuffer', 'Degenerate', 'FacingView',
                                    'Translucent', 'IsShadowMask', 'IsShadow']})
POLYGON.update(FinalZ=('i', 10), FinalW=('i', 10))
CONTEXT = {n: ('I', 1) for n in ['GXStat', 'MatrixMode', 'NumCommands', 'CurCommand',
    'ParamCount', 'TotalParams', 'ExecParamCount', 'NumPushPopCommands', 'NumTestCommands',
    'PolygonMode', 'PolygonAttr', 'CurPolygonAttr', 'TexParam', 'TexPalette',
    'VertexNum', 'VertexNumInPoly', 'NumConsecutivePolygons', 'NumOpaquePolygons']}
CONTEXT.update({n: ('i', 16) for n in ['ProjMatrix', 'PosMatrix', 'VecMatrix',
    'TexMatrix', 'ClipMatrix', 'ProjMatrixStack', 'TexMatrixStack']})
CONTEXT.update(PosMatrixStack=('i', 512), VecMatrixStack=('i', 512),
    ProjMatrixStackPointer=('i', 1), PosMatrixStackPointer=('i', 1),
    TexMatrixStackPointer=('i', 1), Viewport=('I', 6),
    CurVertex=('h', 3), VertexColor=('B', 3), TexCoords=('h', 2),
    RawTexCoords=('h', 2), Normal=('h', 3), LightDirection=('h', 12),
    SpecRecip=('i', 4), LightColor=('B', 12),
    MatDiffuse=('B', 3), MatAmbient=('B', 3), MatSpecular=('B', 3),
    MatEmission=('B', 3), ShininessTable=('B', 128),
    UseShininessTable=('?', 1), ClipMatrixDirty=('?', 1),
    GeometryEnabled=('?', 1), RenderingEnabled=('?', 1), AbortFrame=('?', 1),
    PosTestResult=('i', 4), VecTestResult=('h', 3))
CURRENT = {'DispCnt': ('I', 1), 'AlphaRefVal': ('B', 1), 'AlphaRef': ('B', 1),
    'ToonTable': ('H', 32), 'EdgeTable': ('H', 8), 'FogColor': ('I', 1),
    'FogOffset': ('I', 1), 'FogDensityTable': ('B', 32),
    'ClearAttr1': ('I', 1), 'ClearAttr2': ('I', 1)}
LATCHED = {'RenderDispCnt': ('I', 1), 'RenderAlphaRef': ('B', 1),
    'RenderToonTable': ('H', 32), 'RenderEdgeTable': ('H', 8),
    'RenderFogColor': ('I', 1), 'RenderFogOffset': ('I', 1),
    'RenderFogShift': ('I', 1), 'RenderFogDensityTable': ('B', 34),
    'RenderClearAttr1': ('I', 1), 'RenderClearAttr2': ('I', 1), 'RenderXPos': ('H', 1)}

def require(condition,message):
 if not condition:raise ValueError(message)
def digest(data):return hashlib.sha256(data).hexdigest()
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
def seal(seed):
 seed=copy.deepcopy(seed);seed.pop('semantic_sha256',None);seed['semantic_sha256']=digest(canonical(seed));return seed
