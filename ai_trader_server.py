# ai_trader_server.py
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os
import openai
import time
import json
from typing import List, Dict, Optional

# تنظیم API Key - بهتر است از متغیرهای محیطی استفاده شود
openai.api_key = os.getenv("OPENAI_API_KEY")

app = FastAPI(title="AI Trading Server", version="1.0.0")

class MarketState(BaseModel):
    symbol: str
    timeframe: str
    price: float
    indicators: Dict[str, float]
    positions: List[Dict]

SYSTEM_PROMPT = (
    "You are an expert XAUUSD trading assistant. "
    "Analyze the market data and provide trading signals. "
    "Reply with pure JSON format only: {\"action\":\"BUY|SELL|HOLD\",\"lot\":0.01,\"reason\":\"brief explanation\"}. "
    "Never add extra text outside the JSON structure."
)

def call_gpt(user_prompt: str) -> str:
    """تماس با OpenAI API برای دریافت سیگنال"""
    try:
        response = openai.ChatCompletion.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.2,
            max_tokens=100,
        )
        return response.choices[0].message.content.strip()
    except Exception as e:
        print(f"Error calling OpenAI API: {e}")
        return '{"action":"HOLD","lot":0.0,"reason":"API error"}'

@app.get("/")
def read_root():
    return {"message": "AI Trading Server is running", "status": "active"}

@app.post("/signal")
def get_signal(ms: MarketState):
    """دریافت سیگنال ترید بر اساس وضعیت بازار"""
    try:
        prompt = (
            f"Symbol: {ms.symbol}\n"
            f"Timeframe: {ms.timeframe}\n"
            f"Current Price: {ms.price}\n"
            f"Technical Indicators: {json.dumps(ms.indicators)}\n"
            f"Open Positions: {json.dumps(ms.positions)}\n"
            "Based on this data, what trading action should we take? "
            "Consider risk management and current market conditions."
        )
        
        result = call_gpt(prompt)
        print(f"Raw AI response: {result}")
        
        # پردازش پاسخ AI
        try:
            # حذف احتمالی کدهای اضافی از پاسخ
            result = result.replace('```json', '').replace('```', '').strip()
            decision = json.loads(result)
            
            # اعتبارسنجی ساختار پاسخ
            if "action" not in decision:
                decision = {"action": "HOLD", "lot": 0.0, "reason": "Invalid response structure"}
            if "lot" not in decision:
                decision["lot"] = 0.01  # لات پیش‌فرض
                
        except json.JSONDecodeError as e:
            print(f"JSON parse error: {e}")
            decision = {"action": "HOLD", "lot": 0.0, "reason": "JSON parsing failed"}
        
        # اضافه کردن timestamp
        decision["server_time"] = int(time.time())
        decision["symbol"] = ms.symbol
        decision["received_price"] = ms.price
        
        return decision
        
    except Exception as e:
        print(f"Server error: {e}")
        return {
            "action": "HOLD", 
            "lot": 0.0, 
            "reason": f"Server error: {str(e)}",
            "server_time": int(time.time())
        }

@app.get("/health")
def health_check():
    """بررسی وضعیت سرور"""
    return {
        "status": "healthy",
        "timestamp": int(time.time()),
        "openai_key_set": bool(os.getenv("OPENAI_API_KEY"))
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app, 
        host="0.0.0.0", 
        port=8000,
        log_level="info"
    )