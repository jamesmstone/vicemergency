FROM python:alpine
RUN pip install sqlite-utils
ENTRYPOINT ["sqlite-utils"]
