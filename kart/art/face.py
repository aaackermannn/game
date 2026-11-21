# Builds the chibi face features on object "Face" under "Head". Params set before exec: EX, EZ, ES (eye scale), MZ
import bpy, bmesh, math
from mathutils import Vector
head=bpy.data.objects["Head"]; face=bpy.data.objects["Face"]
for o in list(head.children):
    if o.name not in ("Face",) and not o.name.startswith(("Helmet","Visor","Hair","Ear","Chin")): bpy.data.objects.remove(o,do_unlink=True)
FC=Vector(face.location)
def surf(dx,dz,push=0.0):
    d=Vector((dx,1.0,dz)).normalized()
    hit,loc,nor,_=face.ray_cast(Vector((0,0,0)),d)
    return FC+loc+nor*push, nor
def place(ob,p,n,spin=0.0):
    ob.parent=head; ob.location=p
    ob.rotation_euler=n.to_track_quat('Y','Z').to_euler()
    if spin: ob.rotation_euler.rotate_axis('Y',spin)
for s in (-1,1):
    p,n=surf(s*EX,EZ)
    sc=sphere(f"Sclera{s}",1,(0,0,0),"White",scale=(0.085*ES,0.03,0.11*ES),segs=28,rings=14); place(sc,p,n,s*-0.1)
    off=Vector((s*-0.008,0,-0.01))*ES
    ir=sphere(f"Iris{s}",1,(0,0,0),"Iris",scale=(0.068*ES,0.03,0.092*ES),segs=28,rings=14); place(ir,p+n*0.01+off,n)
    ir2=sphere(f"IrisDark{s}",1,(0,0,0),"Mouth",scale=(0.066*ES,0.02,0.04*ES),segs=20,rings=10); place(ir2,p+n*0.016+off+Vector((0,0,0.045*ES)),n)
    pu=sphere(f"Pupil{s}",1,(0,0,0),"Lash",scale=(0.034*ES,0.02,0.05*ES),segs=16,rings=8); place(pu,p+n*0.024+off,n)
    h1=sphere(f"Shine{s}",1,(0,0,0),"White",scale=(0.026*ES,0.012,0.03*ES),segs=12,rings=6); place(h1,p+n*0.036+Vector((s*0.018,0,0.035))*ES,n)
    h2=sphere(f"Shine2{s}",1,(0,0,0),"White",scale=(0.012*ES,0.008,0.012*ES),segs=8,rings=5); place(h2,p+n*0.034+Vector((s*-0.03,0,-0.045))*ES,n)
    pts=[]
    for i in range(7):
        a=math.radians(-80+i*26.6)
        q,_=surf(s*EX - math.sin(a)*0.13*ES*s, EZ+math.cos(a)*0.16*ES+0.012, 0.014); pts.append(q)
    for i,(a,b) in enumerate(zip(pts,pts[1:])):
        w=0.018 if 1<=i<=4 else 0.012
        tube(f"Lash{s}{i}",a,b,w,"Lash",parent=head); sphere(f"LashJ{s}{i}",w,tuple(b),"Lash",segs=8,rings=5,parent=head)
    sphere(f"LashJ0{s}",0.012,tuple(pts[0]),"Lash",segs=8,rings=5,parent=head)
    tube(f"LashFlick{s}",pts[0],pts[0]+Vector((s*0.045,0.0,0.028)),0.011,"Lash",segs=6,parent=head)
    b0,_=surf(s*(EX-0.17),EZ+0.24,0.012); b1,_=surf(s*EX,EZ+0.3,0.012); b2,_=surf(s*(EX+0.17),EZ+0.27,0.012)
    for i,(a,b) in enumerate([(b0,b1),(b1,b2)]):
        tube(f"Brow{s}{i}",a,b,0.022,"Hair",parent=head); sphere(f"BrowJ{s}{i}",0.022,tuple(b),"Hair",segs=8,rings=5,parent=head)
    sphere(f"BrowJ0{s}",0.022,tuple(b0),"Hair",segs=8,rings=5,parent=head)
    cp,cn=surf(s*(EX+0.2),EZ-0.2,0.004)
    bl=sphere(f"Blush{s}",1,(0,0,0),"Tongue",scale=(0.05,0.008,0.026),segs=12,rings=6); place(bl,cp,cn)
np_,nn=surf(0,EZ-0.13); nose=sphere("Nose",1,(0,0,0),"Skin",scale=(0.022,0.02,0.018),segs=12,rings=8); place(nose,np_,nn)
mp,mn=surf(0,MZ,-0.006)
bm=bmesh.new(); bmesh.ops.create_uvsphere(bm,u_segments=24,v_segments=12,radius=1)
bmesh.ops.delete(bm,geom=[v for v in bm.verts if v.co.z>0.05],context='VERTS')
me=bpy.data.meshes.new("Mouth"); bm.to_mesh(me); bm.free()
mouth=link(bpy.data.objects.new("Mouth",me),"Mouth"); mouth.scale=(0.09,0.025,0.065); place(mouth,mp+Vector((0,0,0.022)),mn)
teeth=sphere("Teeth",1,(0,0,0),"White",scale=(0.076,0.012,0.016),segs=16,rings=8); place(teeth,mp+mn*0.008+Vector((0,0,0.013)),mn)
tg=sphere("Tongue",1,(0,0,0),"Tongue",scale=(0.042,0.012,0.02),segs=12,rings=6); place(tg,mp+mn*0.006+Vector((0,0,-0.024)),mn)
