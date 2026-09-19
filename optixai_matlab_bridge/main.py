import os
import uuid
import tempfile
import subprocess
from fastapi import FastAPI, Depends, HTTPException, Security, status
from fastapi.security import APIKeyHeader
from pydantic import BaseModel
from supabase import create_client, Client
from dotenv import load_dotenv

# Load environment variables (for local dev)
load_dotenv()

app = FastAPI(title="OptiXAI MATLAB Bridge (Vercel)")

# -----------------------------------------------------------------------------
# Configuration & Auth
# -----------------------------------------------------------------------------
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
API_KEY = os.environ.get("BRIDGE_API_KEY", "dev_secret_key_123")

if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
    print("WARNING: Supabase credentials missing. Webhook will fail.")

# Use service role key to bypass RLS for server-side insertions/uploads
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY) if SUPABASE_URL else None

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

def get_api_key(api_key_header: str = Security(api_key_header)):
    if api_key_header == API_KEY:
        return api_key_header
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Could not validate credentials",
    )

# -----------------------------------------------------------------------------
# Models
# -----------------------------------------------------------------------------
class WebhookPayload(BaseModel):
    screening_id: str
    image_url: str  # The full Supabase URL from the database
    eye_side: str  # 'left' or 'right'

# -----------------------------------------------------------------------------
# Endpoints
# -----------------------------------------------------------------------------
@app.post("/api/webhook/gradcam")
async def process_gradcam_sync(payload: WebhookPayload, api_key: str = Depends(get_api_key)):
    """
    Synchronous Webhook to process the image and generate a Grad-CAM heatmap.
    Because Vercel serverless functions freeze immediately after returning a response,
    we CANNOT use BackgroundTasks here. We must await the execution.
    The dummy Python script is fast enough to execute well within the 10-second limit.
    """
    if payload.eye_side not in ['left', 'right']:
        raise HTTPException(status_code=400, detail="Invalid eye_side")

    if not supabase:
        raise HTTPException(status_code=500, detail="Supabase client not configured")

    try:
        # 1. Download the original image securely using the Supabase Service Role
        # This bypasses RLS and works even though 'fundus-images' is a private bucket.
        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = os.path.join(tmpdir, f"{payload.screening_id}_in.jpg")
            output_path = os.path.join(tmpdir, f"{payload.screening_id}_{payload.eye_side}_gradcam.png")
            
            try:
                # Parse the storage path from the full URL (e.g. https://.../fundus-images/patient/file.jpg -> patient/file.jpg)
                storage_path = payload.image_url.split("fundus-images/")[-1].split("?")[0].lstrip("/")
                
                # Download returns the bytes of the file
                image_bytes = supabase.storage.from_("fundus-images").download(storage_path)
                with open(input_path, 'wb') as f:
                    f.write(image_bytes)
            except Exception as dl_err:
                raise HTTPException(status_code=400, detail=f"Failed to download image from storage: {dl_err}")
            
            # 2. Execute the dummy MATLAB script SYNCHRONOUSLY using native Python
            # We import and run the function directly, bypassing `subprocess` which 
            # is extremely flaky in Vercel Serverless environments.
            from generate_dummy_heatmap import generate_heatmap
            print(f"Executing native heatmap generator on {input_path}")
            try:
                generate_heatmap(input_path, output_path)
            except Exception as script_e:
                print(f"Heatmap generation failed: {script_e}")
                raise HTTPException(status_code=500, detail="Heatmap generation failed")
            
            # 3. Read the generated output
            with open(output_path, 'rb') as f:
                output_bytes = f.read()
                
            # 4. Upload to Supabase Storage ('heatmaps' bucket)
            storage_path = f"{payload.screening_id}/{payload.eye_side}_gradcam.png"
            
            # The python SDK might fail if the file already exists unless we upsert
            try:
                res = supabase.storage.from_("heatmaps").upload(
                    file=output_bytes,
                    path=storage_path,
                    file_options={"content-type": "image/png", "upsert": "true"}
                )
            except Exception as e:
                # If upload fails, try update
                try:
                    res = supabase.storage.from_("heatmaps").update(
                        file=output_bytes,
                        path=storage_path,
                        file_options={"content-type": "image/png", "upsert": "true"}
                    )
                except Exception as inner_e:
                    raise Exception(f"Failed to upload to storage: {str(e)} | {str(inner_e)}")
            
            # 5. Get the public URL
            heatmap_url = supabase.storage.from_("heatmaps").get_public_url(storage_path)
            
            # 6. Insert DB record into `heatmaps` table to link screening and heatmap
            db_response = supabase.table('heatmaps').insert({
                "screening_id": payload.screening_id,
                "heatmap_url": heatmap_url
            }).execute()
            
            return {
                "status": "success",
                "message": "Grad-CAM heatmap generated and uploaded.",
                "heatmap_url": heatmap_url
            }

    except Exception as e:
        print(f"Error processing webhook: {e}")
        raise HTTPException(status_code=500, detail=str(e))
