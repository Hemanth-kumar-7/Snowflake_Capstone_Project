
--Step-1 Ingestion Layer

-- 1. Create Database and Schema
CREATE DATABASE IF NOT EXISTS retail_db;

use database retail_db;

CREATE SCHEMA IF NOT EXISTS sales_schema;

use schema sales_schema;


-- 2. Create a File Formate for the CSV 
CREATE OR REPLACE FILE FORMAT retail_csv_format
TYPE = 'CSV'
SKIP_HEADER = 1
FIELD_OPTIONALLY_ENCLOSED_BY = '"';


-- 3. Create an Internal Stage
create or replace stage retail_stage
file_format = retail_csv_format;

-- 4. Create Raw Table
CREATE OR REPLACE TABLE stg_orders(
Row_ID NUMBER,
Order_ID VARCHAR(50),
Order_Date DATE,
Ship_Date DATE,
Ship_Mode VARCHAR(200),
Customer_ID VARCHAR(50),
Customer_Name VARCHAR(300),
Segment VARCHAR(100),
Country VARCHAR(100),
City VARCHAR(100),
State VARCHAR(100),
Postal_Code NUMBER(10),
Region VARCHAR(100),
Product_ID VARCHAR(100),
Category VARCHAR(100),
Sub_Category VARCHAR(100),
Product_Name VARCHAR(1000),
Price NUMBER(10,4),
Quantity NUMBER(3),
Discount NUMBER(7,2)
);

-- 5. Load Data
copy into stg_orders
from @retail_stage
file_format = (format_name='retail_csv_format');


-- 6. Verify Loaded Data
SELECT Count(*) 
From STG_ORDERS;



-- Step-2 Transformations Layer( Creating UDFs)

-- UDF 1: Order Year 
CREATE or REPLACE FUNCTION EXTRACT_Year(Order_ID VARCHAR)
RETURNS NUMBER(4)
as
$$
CAST(REGEXP_SUBSTR(Order_ID,'[0-9]{4}') AS NUMBER(4))
$$;

-- UDF 2: Days To Ship
CREATE OR REPLACE FUNCTION calc_days_to_ship(Order_Date DATE, Ship_Date DATE)
RETURNS NUMBER(3)
AS
$$
 DATEDIFF(day, Order_Date, Ship_Date)
$$;

-- UDF 3: Customer ID Cleaning
CREATE or REPLACE FUNCTION Clean_Customer_ID(Customer_ID VARCHAR)
RETURNS NUMBER(10)
as
$$
CAST(REGEXP_REPLACE(Customer_ID,'[^0-9]', '') AS NUMBER(10))
$$;

-- UDF 4: Order ID Cleaning
CREATE or REPLACE FUNCTION Clean_order_ID(Order_ID VARCHAR)
RETURNS NUMBER(10)
as
$$
CAST(REGEXP_REPLACE(Order_ID,'[^0-9]', '') AS NUMBER(10))
$$;

-- UDF 5: Product ID Cleaning
CREATE or REPLACE FUNCTION Clean_Product_ID(Product_ID VARCHAR)
RETURNS NUMBER(10)
as
$$
CAST(REGEXP_REPLACE(Product_ID,'[^0-9]', '') AS NUMBER(10))
$$;

-- UDF 6: Sales Calculation
CREATE OR REPLACE FUNCTION calc_sales(Price NUMBER(10,4), Quantity NUMBER(3))
RETURNS NUMBER(15,5)
AS
$$
 Price*Quantity
$$;

-- Create Final Table
CREATE OR REPLACE TABLE Retail_Table(
Order_ID NUMBER(10),
Order_Date DATE,
Ship_Date DATE,
Ship_Mode VARCHAR(200),
Customer_ID NUMBER(10),
Customer_Name VARCHAR(300),
Segment VARCHAR(100),
Country VARCHAR(100),
City VARCHAR(100),
State VARCHAR(100),
Postal_Code NUMBER(10),
Region VARCHAR(100),
Product_ID NUMBER(10),
Category VARCHAR(100),
Sub_Category VARCHAR(100),
Price NUMBER(10,4),
Quantity NUMBER(3),
Discount NUMBER(7,2),
Order_Year NUMBER(4),
Days_To_Ship NUMBER(3),
Sales NUMBER(15,5)
);

-- Insert And Transform Data
INSERT INTO RETAIL_TABLE 
select
    Clean_order_ID(Order_ID),
    Order_Date,
    Ship_Date,
    Ship_Mode,
    Clean_Customer_ID(Customer_ID),
    Customer_Name,
    Segment,
    Country,
    City,
    State,
    Postal_Code,
    Region,
    Clean_Product_ID(Product_ID),
    Category,
    Sub_Category,
    Price,
    Quantity,
    Discount,
    EXTRACT_Year(Order_ID),
    calc_days_to_ship(Order_Date,Ship_Date),
    calc_sales(Price,Quantity)
    from STG_ORDERS;

-- Verifying Retail Table
SELECT * from retail_table;


-- C. Processing Layer 

-- 1. Create The Stream
CREATE OR REPLACE STREAM Orders_Stream
ON TABLE STG_ORDERS;

-- 2. Create The Scheduled Task With MERGE Statement
CREATE OR REPLACE TASK Daily_Sales_Merge_Task
WAREHOUSE = COMPUTE_WH
SCHEDULE = '1440 MINUTE'
WHEN
    SYSTEM$STREAM_HAS_DATA('Orders_Stream')
AS  MERGE INTO RETAIL_TABLE tgt 
using (
    SELECT
        Clean_order_ID(Order_ID)as Order_id,
        Order_Date,Ship_Date,Ship_Mode,Clean_Customer_ID(Customer_ID) as Customer_ID,
        Customer_Name,Segment,Country,City,State,Postal_Code,Region,
        Clean_Product_ID(Product_ID) as Product_ID,Category,
        Sub_Category,Price,Quantity,Discount,EXTRACT_Year(Order_ID) as Order_Year,
        calc_days_to_ship(Order_Date,Ship_Date) as Days_To_Ship,
        calc_sales(Price,Quantity) as Sales,
        METADATA$ACTION,
        METADATA$ISUPDATE
    FROM ORDERS_STREAM
) src 
ON tgt.order_id = src.order_id AND tgt.product_id = src.product_id
-- Handle Updates
WHEN MATCHED AND src.METADATA$ACTION = 'INSERT' AND src.METADATA$ISUPDATE = TRUE THEN
    UPDATE SET
        tgt.Ship_Date = src.Ship_Date,
        tgt.Ship_Mode = src.Ship_Mode,
        tgt.Price = src.Price,
        tgt.Quantity = src.Quantity,
        tgt.Discount = src.Discount,
        tgt.Days_To_Ship = src.Days_To_Ship,
        tgt.Sales = src.Sales
-- Handle Deletes
WHEN MATCHED AND src.METADATA$ACTION = 'DELETE' THEN
    DELETE
-- Handle Inserts
WHEN NOT MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
    INSERT(
        Order_id,Order_Date,Ship_Date,Ship_Mode,Customer_ID,Customer_Name,
        Segment,Country,City,State,Postal_Code,Region,Product_ID,Category,
        Sub_Category,Price,Quantity,Discount,Order_Year,Days_To_Ship,Sales)
    VALUES(
        src.Order_id,src.Order_Date,src.Ship_Date,src.Ship_Mode,src.Customer_ID,src.Customer_Name,
        src.Segment,src.Country,src.City,src.State,src.Postal_Code,src.Region,src.Product_ID,src.Category,
        src.Sub_Category,src.Price,src.Quantity,src.Discount,src.Order_Year,src.Days_To_Ship,src.Sales);


-- 3. Activate The Task
ALTER TASK Daily_Sales_Merge_Task RESUME;


-- D. Visualization Layer

--1. Highest Performing Cities(Heat Grid)
SELECT City, SUM(Sales) as Total_Sales
FROM RETAIL_TABLE
GROUP BY City
ORDER BY Total_Sales DESC;


--2. Average Delivery Time Across Shipping Modes (Bar Chart)
SELECT Ship_mode, AVG(Days_To_Ship) as Avg_Delivery_Days
FROM RETAIL_TABLE
GROUP BY Ship_mode
ORDER BY Avg_Delivery_Days ASC;


-- 3.Sales Performance Across Customer Segments Over Multiple Years(Line Chart)
SELECT Order_Year, Segment, SUM(Sales) as Total_Sales
FROM RETAIL_TABLE
GROUP BY Order_Year, Segment
ORDER BY Order_Year ASC;


-- 4.Average Order Value Between Customer Segments(Bar Chart)
SELECT Segment, AVG(sales) as Avg_Order_Value
FROM RETAIL_TABLE
GROUP BY Segment;


-- 5.Repeat Customers
SELECT COUNT(Customer_ID) As Repeat_Customers
FROM(
    SELECT Customer_ID
    FROM RETAIL_TABLE
    GROUP BY Customer_ID
    HAVING COUNT(DISTINCT ORDER_ID)>1
);


-- 6. High Sales/Low Order Quadrant
SELECT Product_ID, COUNT(DISTINCT Order_ID) as Order_Count,SUM(Sales) as Total_Sales
From RETAIL_TABLE
GROUP BY Product_ID;



-- E. AI/ML Layer

-- 1.Retail Sales Cortex Analyst
CREATE OR REPLACE VIEW RETAIL_SALES AS
SELECT 
    Order_id,Order_Date,Ship_Date,Ship_Mode,Customer_ID,Customer_Name,
    Segment,Country,City,State,Postal_Code,Region,Product_ID,Category,
    Sub_Category,Price,Quantity,Discount,Order_Year,Days_To_Ship,Sales,
    ROUND(Price * Quantity * (1 - discount), 2) AS Revenue
FROM RETAIL_TABLE;


-- 2.Cortex LLM - Summarize Insights
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large',
    'Summarize Revenue trend by Region and Category using Order_Date for the last 
    6 months based on this date: ' || (
    SELECT LISTAGG(Region || ',' || Category || ',' || TO_CHAR(Order_Date) || ',' || Revenue, '; ')
    FROM RETAIL_SALES
    WHERE ORDER_DATE >= DATEADD('month', -6, CURRENT_DATE()))
) AS Summary;


-- 3.ML Forecast-Daily Revenue By Region
  -- Create Aggregated Table for Forecasting
CREATE OR REPLACE VIEW Daily_Revenue_View AS
SELECT 
    Order_Date, Region, SUM(Sales) as Total_Revenue
FROM RETAIL_SALES
WHERE ORDER_DATE IS NOT NULL AND ORDER_DATE >= '2000-01-01'
GROUP BY ORDER_DATE, REGION;

DESC TABLE DAILY_REVENUE;

 -- Create Forecaste Model
 CREATE OR REPLACE SNOWFLAKE.ML.FORECAST Revenue_Forecast(
    INPUT_DATA => SYSTEM$REFERENCE('VIEW','Daily_Revenue_View'),
    SERIES_COLNAME => 'Region',
    TIMESTAMP_COLNAME => 'Order_Date',
    TARGET_COLNAME => 'Total_Revenue'
);


-- 4. Cortex Search Setup
-- Create policy documents table
CREATE OR REPLACE TABLE Business_Policies(
    Policy_ID NUMBER AUTOINCREMENT,
    Policy_Name VARCHAR(200),
    Policy_Text VARCHAR(5000)
);

INSERT INTO BUSINESS_POLICIES(Policy_Name, Policy_Text)
VALUES
   ('Discount Policy',
    'High discount oders above 30% in Furnitur Category require manager approval.
    Standard discount cap is 20% for Office Supplies and !5% for Technology.'),
    ('Shipping Rule',
    'Standard Class shipping takes 5-7 days. Second Class 3-5 days.
    First class 2-3 days, Same Day delivery available in select cities only.');

-- Create Cortex Search Service 
CREATE OR REPLACE CORTEX SEARCH SERVICE Policy_Search_Service
    ON Policy_text 
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 hour'
AS(
    SELECT Policy_Name, Policy_Text 
    FROM BUSINESS_POLICIES
);
    
        

    
    
    



